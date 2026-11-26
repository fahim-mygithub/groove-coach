import AVFoundation
import Combine
import CoreGraphics
import GrooveCore
import SwiftUI

// MARK: - Controller

/// Runs pre-take studio + body calibration (spec: `docs/specs/2026-11-26-calibration-v2-plan.md`):
/// feeds `CalibrationGate` from CoreMotion (30 Hz), live MediaPipe poses (camera analysis queue),
/// LiDAR `CalibrationDepthSample`s (8 Hz in `.rearLiDAR`), and 2 Hz light + `exposureLocked` samples;
/// locks/unlocks AE/AWB on `needsExposureLock`; persists `CalibrationProfileV2` via `CalibrationProfileStore`;
/// and drives `CalibrationVoice`, `CalibrationOverlayView`, and `DebugLink`.
@MainActor
final class CalibrationController: ObservableObject {
    struct Outcome {
        /// Legacy v1 profile (`frames` + device `gravity`); nil when skipped (`calibration_frames = nil`).
        let profile: CalibrationProfile?
        /// Persisted v2 profile (`groove.calibration/2`); nil when skipped.
        let profileV2: CalibrationProfileV2?
        /// Device-frame gravity locked by the gate (latest reading when skipped), nil if no motion reading arrived.
        let gravity: [Double]?
        /// Camera-frame gravity aligned with `CanonicalSkeleton` axes (`+x` right, `+y` up, `+z` toward lens; §1.2).
        let cameraGravity: [Double]?
        let skipped: Bool
        let resumed: Bool
        let resumedBody: Bool
        let calibrationTier: CalibrationResumeTier

        init(
            profile: CalibrationProfile?,
            profileV2: CalibrationProfileV2? = nil,
            gravity: [Double]?,
            cameraGravity: [Double]? = nil,
            skipped: Bool,
            resumed: Bool,
            resumedBody: Bool = false,
            calibrationTier: CalibrationResumeTier = .tier2FullCalibration
        ) {
            self.profile = profile
            self.profileV2 = profileV2
            self.gravity = gravity
            self.cameraGravity = cameraGravity
            self.skipped = skipped
            self.resumed = resumed
            self.resumedBody = resumedBody
            self.calibrationTier = calibrationTier
        }
    }

    /// The gate's status while calibration is active; nil when idle.
    @Published private(set) var status: CalibrationStatus?
    @Published private(set) var rollDeg: Double?
    @Published private(set) var tiltBackDeg: Double?
    @Published private(set) var tuning: CalibrationTuning = .defaults
    @Published private(set) var cameraMode: CameraMode = .frontSelfView
    @Published private(set) var calibrationTier: CalibrationResumeTier = .tier2FullCalibration
    @Published private(set) var completedSteps: Set<CalibrationStep> = []
    @Published private(set) var lastLockedProfileV2: CalibrationProfileV2?

    /// True once Pose 6 (`.plie`) has progressed past initial entry so overlay text switches from entry to diagnostic.
    @Published private(set) var hasEnteredPlieHold = false

    /// Legacy in-memory profile bridge preserved for v1 compatibility.
    static var lastProfile: CalibrationProfile?

    let sensors = CalibrationSensors()
    let voice = CalibrationVoice()
    let profileStore: CalibrationProfileStore

    private let screen: String
    private var gate = CalibrationGate()
    private weak var camera: PracticeCamera?
    private weak var lastCaptureDevice: AVCaptureDevice?
    private var installedGestureHandler = false
    private var onFinish: ((Outcome) -> Void)?
    private var running = false
    private var linkSession = false
    private var tuningSub: AnyCancellable?
    private var lastAppliedExposureLock = false
    private var latestLightSample: CalibrationLightSample?
    private var seededMonocularFoV = false
    private var lastSeededVideoIntrinsics: CalibrationIntrinsics?
    private var previousStep: CalibrationStep?

    init(screen: String, profileStore: CalibrationProfileStore = .shared) {
        self.screen = screen
        self.profileStore = profileStore
        self.lastLockedProfileV2 = profileStore.activeProfileV2
        sensors.onMotion = { [weak self] m in
            // CMMotionManager delivers on the main queue.
            MainActor.assumeIsolated { self?.ingest(motion: m) }
        }
        if ExternalDisplayManager.shared.onRecalibrateStudioRequested == nil {
            ExternalDisplayManager.shared.onRecalibrateStudioRequested = { [weak profileStore] in
                profileStore?.requestFullRecalibration()
            }
        }
    }

    var isRunning: Bool { running }

    func startSensors() {
        sensors.startMotion()
    }

    func stopSensors() {
        let device = camera?.captureDevice ?? lastCaptureDevice
        cancel()
        sensors.unlockExposureAndWhiteBalance(on: device)
        lastAppliedExposureLock = false
        sensors.stopMotion()
    }

    func currentGravity() -> [Double] {
        sensors.currentGravity()
    }

    func currentCameraGravity(for mode: CameraMode? = nil) -> [Double] {
        sensors.currentCameraGravity(for: mode ?? camera?.activeCameraMode ?? cameraMode)
    }

    /// Unlocks AE/AWB on both the sensor state tracker and the hardware capture device (§3.3).
    func unlockExposure() {
        sensors.unlockExposureAndWhiteBalance(on: camera?.captureDevice ?? lastCaptureDevice)
        lastAppliedExposureLock = false
    }

    /// Evaluates the between-take 2 Hz luma drift re-meter guard (§3.3).
    func evaluateBetweenTakeRemeter(meanLuma: Double, at time: Double) {
        _ = sensors.evaluateRemeterIfNeeded(
            meanLuma: meanLuma,
            at: time,
            device: camera?.captureDevice ?? lastCaptureDevice,
            allowRemeter: true,
            tuning: tuning
        )
    }

    /// Repeats the active spoken cue immediately (single-clap in `.calibrating`; §5.2).
    func repeatCurrentCue() {
        guard running, let st = status else { return }
        voice.repeatCurrentCue(
            dancerDistanceM: st.dancerDistanceM,
            effectiveMinDistanceM: st.effectiveMinDistanceM
        )
    }

    /// Starts calibration on `camera`; `onFinish` runs once on lock or Skip (not on `cancel()`).
    func begin(
        camera: PracticeCamera,
        forceFullRecalibration: Bool = false,
        onFinish: @escaping (Outcome) -> Void
    ) {
        cancel()
        sensors.startMotion()
        self.camera = camera
        self.lastCaptureDevice = camera.captureDevice

        // Start `.level` and Pose 1 `.rest` with continuous auto-exposure / auto-white-balance (§3.3).
        sensors.unlockExposureAndWhiteBalance(on: camera.captureDevice)
        lastAppliedExposureLock = false
        latestLightSample = nil
        seededMonocularFoV = false
        lastSeededVideoIntrinsics = nil
        hasEnteredPlieHold = false
        completedSteps = []
        previousStep = nil

        if camera.deviceGravityProvider == nil {
            let motionSensors = sensors
            camera.deviceGravityProvider = { [weak motionSensors] in
                motionSensors?.currentGravity() ?? [0.0, -1.0, 0.0]
            }
        }
        camera.updateDeviceGravity(sensors.currentGravity())

        self.onFinish = onFinish
        running = true

        let link = DebugLink.shared
        link.beginSession()
        linkSession = true
        let t = link.tuning ?? .defaults
        tuning = t

        let mode = camera.activeCameraMode
        cameraMode = mode
        let stored = profileStore.activeProfileV2 ?? profileStore.reload()
        let forceFull = forceFullRecalibration || profileStore.forceFullRecalibrationNext
        let sameSession = profileStore.hasCalibratedInCurrentSession && !forceFull

        if stored == nil, !forceFull, mode == .frontSelfView, let legacy = Self.lastProfile {
            gate = CalibrationGate(tuning: t, resume: legacy)
        } else {
            gate = CalibrationGate(
                tuning: t,
                cameraMode: mode,
                storedProfile: stored,
                isSameSession: sameSession,
                forceFullRecalibration: forceFull,
                deviceModel: DebugLinkDevice.model
            )
        }

        // Seed initial camera FoV / video intrinsics so §3.5 FoV-coupled span bounds are active from frame 0.
        let initialFoV = camera.verticalFoVDeg
        let initialIntrinsics = camera.latestVideoIntrinsics
        if initialFoV > 0 || initialIntrinsics != nil {
            gate.update(
                depth: CalibrationDepthSample(
                    timestamp: 0,
                    verticalFoVDeg: initialFoV > 0 ? initialFoV : nil,
                    intrinsics: initialIntrinsics
                )
            )
            seededMonocularFoV = initialFoV > 0
            lastSeededVideoIntrinsics = initialIntrinsics
        }

        calibrationTier = gate.calibrationTier
        rollDeg = nil
        tiltBackDeg = nil
        previousStep = gate.step
        status = gate.status
        voice.reset()
        voice.update(status: gate.status, calibrationTier: gate.calibrationTier)

        tuningSub = link.$tuning.dropFirst().sink { [weak self] newValue in
            MainActor.assumeIsolated { self?.apply(tuning: newValue ?? .defaults) }
        }

        // Install Phase-1 `.calibrating` clap / double-clap handler unless a stage coordinator already owns `onGestureEvent`.
        if camera.onGestureEvent == nil && camera.onGestureEventAtTime == nil {
            installedGestureHandler = true
            camera.onGestureEvent = { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.handleCalibrationGesture(event)
                }
            }
        } else {
            installedGestureHandler = false
        }

        let sampler = CalibrationSampler(sensors: sensors)
        camera.startCalibration(
            { [weak self, weak camera] sample in
                // Camera analysis queue: sample 2 Hz luma + exposureLocked and Debug Link JPEG while pixelBuffer is valid.
                let pose = CalibrationPoseSample(
                    timestamp: sample.time,
                    landmarks: sample.landmarks,
                    frame: sample.frame
                )
                let light = sampler.lightIfDue(sample, device: camera?.captureDevice)
                let snapshot = sampler.snapshotIfDue(sample)
                let points = sample.landmarks
                let sampleMode = sample.cameraMode
                let sampleVFoV = sample.verticalFoVDeg
                let sampleIntrinsics = sample.videoIntrinsics
                Task { @MainActor [weak self] in
                    self?.ingest(
                        pose: pose,
                        landmarks: points,
                        light: light,
                        snapshot: snapshot,
                        sampleMode: sampleMode,
                        verticalFoVDeg: sampleVFoV,
                        videoIntrinsics: sampleIntrinsics
                    )
                }
            },
            onDepth: { [weak self] depthSample in
                Task { @MainActor [weak self] in
                    self?.ingest(depth: depthSample)
                }
            }
        )
    }

    /// The Skip button (or double-clap in `.calibrating`): lock immediately without calibration frames.
    func skip() {
        guard running else { return }
        gate.skip()
        publish()
    }

    /// Cancels active calibration without calling `onFinish` (take aborted, AirPlay dropped, or screen exited).
    func cancel() {
        let wasRunning = running
        let device = camera?.captureDevice ?? lastCaptureDevice
        endStreams()
        onFinish = nil
        status = nil
        if wasRunning {
            sensors.unlockExposureAndWhiteBalance(on: device)
            lastAppliedExposureLock = false
            voice.stop()
        }
    }

    private func endStreams() {
        running = false
        if let cam = camera {
            if installedGestureHandler {
                cam.onGestureEvent = nil
            }
            cam.stopCalibration()
        }
        installedGestureHandler = false
        camera = nil
        tuningSub = nil
        if linkSession {
            linkSession = false
            DebugLink.shared.endSession()
        }
    }

    private func apply(tuning newTuning: CalibrationTuning) {
        guard running, newTuning != gate.tuning else { return }
        gate.tuning = newTuning
        tuning = newTuning
    }

    private func handleCalibrationGesture(_ event: GestureEvent) {
        guard running else { return }
        guard let command = GestureRouter.route(event, phase: .calibrating) else { return }
        switch command {
        case .repeatCalibrationCue:
            voice.playEarcon(for: .repeatCalibrationCue)
            repeatCurrentCue()
            DebugLink.shared.recordGestureFired(
                command: event.rawValue,
                mode: GestureMode.calibrating.rawValue,
                phase: CoachingPhase.calibrating.rawValue,
                action: CoachingCommand.repeatCalibrationCue.rawValue,
                extra: ["screen": screen]
            )
        case .skipCalibration:
            voice.playEarcon(for: .skipCalibration)
            DebugLink.shared.recordGestureFired(
                command: event.rawValue,
                mode: GestureMode.calibrating.rawValue,
                phase: CoachingPhase.calibrating.rawValue,
                action: CoachingCommand.skipCalibration.rawValue,
                extra: ["screen": screen]
            )
            skip()
        default:
            break
        }
    }

    // MARK: - Sensor & Camera Streams

    private func ingest(motion m: CalibrationMotionSample) {
        guard running else { return }
        camera?.updateDeviceGravity(m.gravity.array)
        let (roll, tilt) = CalibrationGate.angles(gravity: m.gravity, cameraMode: gate.cameraMode)
        if rollDeg.map({ abs($0 - roll) >= 0.3 }) ?? true { rollDeg = roll }
        if tiltBackDeg.map({ abs($0 - tilt) >= 0.3 }) ?? true { tiltBackDeg = tilt }
        gate.update(motion: m)
        publish()
    }

    private func ingest(depth d: CalibrationDepthSample) {
        guard running else { return }
        gate.update(depth: d)
        publish()
    }

    private func ingest(
        pose: CalibrationPoseSample,
        landmarks: [CalibrationLandmark],
        light: CalibrationLightSample?,
        snapshot: CGImage?,
        sampleMode: CameraMode,
        verticalFoVDeg: Double,
        videoIntrinsics: CalibrationIntrinsics?
    ) {
        guard running else { return }
        if camera?.captureDevice != nil {
            lastCaptureDevice = camera?.captureDevice
        }

        // In monocular modes (`.frontSelfView` / `.rearWide`), keep FoV & per-frame video intrinsics updated on `gate`.
        if !sampleMode.usesLiDAR {
            let needsFoVSeed = !seededMonocularFoV && verticalFoVDeg > 0
            let needsIntrinsicsSeed = videoIntrinsics != nil && videoIntrinsics != lastSeededVideoIntrinsics
            if needsFoVSeed || needsIntrinsicsSeed {
                gate.update(
                    depth: CalibrationDepthSample(
                        timestamp: pose.timestamp,
                        verticalFoVDeg: verticalFoVDeg > 0 ? verticalFoVDeg : nil,
                        intrinsics: videoIntrinsics
                    )
                )
                if verticalFoVDeg > 0 { seededMonocularFoV = true }
                if videoIntrinsics != nil { lastSeededVideoIntrinsics = videoIntrinsics }
            }
        }

        if var lightSample = light {
            lightSample.exposureLocked = sensors.isExposureLocked
            latestLightSample = lightSample
            gate.update(light: lightSample)
        }

        gate.update(pose: pose)

        if let snapshot {
            let st = gate.status
            let framingOK = gate.telemetry().framingOK ?? false
            DebugLink.shared.sendFrame(
                image: snapshot,
                landmarks: landmarks,
                tuning: gate.tuning,
                framingOK: framingOK,
                label: "\(st.step.name) \(st.cue.rawValue)"
            )
        }
        publish()
    }

    private func syncExposureLockIfNeeded(for st: CalibrationStatus) {
        let device = camera?.captureDevice ?? lastCaptureDevice
        if st.needsExposureLock && !lastAppliedExposureLock {
            let lockState = sensors.lockExposureAndWhiteBalance(
                on: device,
                meanLuma: latestLightSample?.meanLuma,
                tuning: gate.tuning
            )
            lastAppliedExposureLock = true

            var updatedLight = latestLightSample ?? CalibrationLightSample(
                meanLuma: lockState.lockedMeanLuma ?? 0.5,
                iso: lockState.lockedISO ?? 0,
                maxISO: Double(device?.activeFormat.maxISO ?? 0),
                exposureSeconds: lockState.lockedExposureDurationS ?? 0,
                exposureLocked: lockState.exposureLocked
            )
            if let lockedISO = lockState.lockedISO, lockedISO > 0 {
                updatedLight.iso = lockedISO
            }
            if let lockedDur = lockState.lockedExposureDurationS, lockedDur > 0 {
                updatedLight.exposureSeconds = lockedDur
            }
            updatedLight.exposureLocked = lockState.exposureLocked
            latestLightSample = updatedLight
            gate.update(light: updatedLight)
        } else if !st.needsExposureLock && lastAppliedExposureLock {
            sensors.unlockExposureAndWhiteBalance(on: device)
            lastAppliedExposureLock = false
            if var updatedLight = latestLightSample {
                updatedLight.exposureLocked = false
                latestLightSample = updatedLight
                gate.update(light: updatedLight)
            }
        }
    }

    private func publish() {
        var st = gate.status
        syncExposureLockIfNeeded(for: st)
        st = gate.status

        if cameraMode != gate.cameraMode {
            cameraMode = gate.cameraMode
        }
        if calibrationTier != gate.calibrationTier {
            calibrationTier = gate.calibrationTier
        }

        if let prev = previousStep, prev != st.step {
            if st.step == .level {
                completedSteps = []
                hasEnteredPlieHold = false
            } else if st.step.rawValue > prev.rawValue {
                completedSteps.insert(prev)
                if st.step == .plie {
                    hasEnteredPlieHold = false
                }
            }
            previousStep = st.step
        }
        if st.step == .plie && st.progress > 0 && !hasEnteredPlieHold {
            hasEnteredPlieHold = true
        }

        if st != status {
            status = st
        }
        voice.update(status: st, calibrationTier: gate.calibrationTier)

        let gateSnapshot = self.gate
        DebugLink.shared.offerTelemetry({ gateSnapshot.telemetry() }, extra: ["screen": screen])
        if st.isLocked {
            finish()
        }
    }

    private func finish() {
        guard running else { return }
        var resolvedV2 = gate.lockedProfileV2
        if !gate.skipped, var lockedV2 = resolvedV2 {
            if let luma = sensors.lockedMeanLuma {
                lockedV2.environment.lockedMeanLuma = luma
            }
            if let iso = sensors.lockedISO, iso > 0 {
                lockedV2.environment.exposureLockedISO = iso
            }
            if let dur = sensors.lockedExposureDurationS, dur > 0 {
                lockedV2.environment.exposureLockedDurationS = dur
            }
            _ = profileStore.save(lockedV2, markSessionCalibrated: true)
            if let saved = profileStore.activeProfileV2 {
                lockedV2 = saved
            }
            resolvedV2 = lockedV2
            lastLockedProfileV2 = lockedV2
        } else if gate.skipped {
            sensors.unlockExposureAndWhiteBalance(on: camera?.captureDevice ?? lastCaptureDevice)
            lastAppliedExposureLock = false
        }

        if let p = gate.lockedProfile {
            Self.lastProfile = p
        }

        let devGravity = gate.lockedGravity
        let camGravity = devGravity.map { gate.cameraMode.cameraFrameGravity(fromDeviceGravity: $0) }
        let outcome = Outcome(
            profile: gate.lockedProfile,
            profileV2: resolvedV2,
            gravity: devGravity,
            cameraGravity: camGravity,
            skipped: gate.skipped,
            resumed: gate.resumed,
            resumedBody: gate.resumedBody,
            calibrationTier: gate.calibrationTier
        )

        DebugLink.shared.sendTelemetry(gate.telemetry(), kind: "calibration_end", extra: ["screen": screen])
        endStreams()
        let callback = onFinish
        onFinish = nil
        callback?(outcome)
    }
}

/// Per-calibration throttles confined to the camera analysis queue.
final class CalibrationSampler: @unchecked Sendable {
    static let lightInterval = 0.5

    private let sensors: CalibrationSensors
    private var lastLight = -Double.infinity
    private var lastSnapshot = -Double.infinity

    init(sensors: CalibrationSensors = CalibrationSensors()) {
        self.sensors = sensors
    }

    func lightIfDue(_ s: CalibrationCameraSample, device: AVCaptureDevice?) -> CalibrationLightSample? {
        guard s.time - lastLight >= Self.lightInterval else { return nil }
        lastLight = s.time
        guard let pair = CalibrationSensors.lightSampleWithExposureLock(
            s.pixelBuffer,
            device: device,
            torso: CalibrationSensors.torsoRect(s.landmarks),
            sensors: sensors
        ) else { return nil }
        var sample = pair.sample
        sample.exposureLocked = pair.exposureLocked
        return sample
    }

    func snapshotIfDue(_ s: CalibrationCameraSample) -> CGImage? {
        guard DebugLinkSettings.isEnabled, s.time - lastSnapshot >= DebugLinkSettings.frameInterval else { return nil }
        lastSnapshot = s.time
        return DebugLinkImaging.snapshot(s.pixelBuffer)
    }
}

// MARK: - Overlay

/// Calibration v2 HUD over the (mirrored) camera preview:
/// - Step label, dynamic spoken instruction (including FoV-derived `effectiveMinDistanceM` distance cues),
///   and 9-pose progress dots in the header.
/// - Bubble level + tilt arc during `.level`.
/// - Target pose mannequin silhouette (`CalibrationPoseSilhouetteView`) + radial `HoldRing` across Poses 1–9.
/// - Framing box across all pose steps (widened to `[0.04, 0.96]` on `.stepLeft`/`.stepRight`), LiDAR distance pill,
///   non-blocking lighting / camera-height advisory pill, Skip button, and Debug Link tuning hash badge.
struct CalibrationOverlayView: View {
    @ObservedObject var controller: CalibrationController
    @ObservedObject private var link = DebugLink.shared
    /// `width / height` of the camera image (the preview is aspect-fit).
    var imageAspect: Double
    var compact: Bool

    init(controller: CalibrationController, imageAspect: Double = 9.0 / 16.0, compact: Bool = false) {
        self.controller = controller
        self.imageAspect = imageAspect
        self.compact = compact
    }

    var body: some View {
        if let st = controller.status {
            GeometryReader { geo in
                let rect = Self.fittedRect(in: geo.size, imageAspect: imageAspect)
                ZStack {
                    if st.step.poseKind != nil || st.isLocked {
                        framingBox(in: rect, status: st)
                    }
                    VStack(spacing: compact ? 6 : 10) {
                        header(st)
                        Spacer(minLength: 0)
                        if st.step == .level {
                            LevelIndicator(
                                rollDeg: controller.rollDeg,
                                tiltBackDeg: controller.tiltBackDeg,
                                tuning: controller.tuning
                            )
                            .frame(width: compact ? 150 : 200, height: compact ? 110 : 150)
                        } else if st.step.poseKind != nil {
                            poseCenterCluster(st)
                        } else if st.progress > 0 || st.isLocked {
                            HoldRing(progress: st.progress, locked: st.isLocked, icon: icon(for: st.step))
                                .frame(width: compact ? 56 : 76, height: compact ? 56 : 76)
                        }
                        advisoryRow(st)
                        footer(st)
                    }
                    .padding(compact ? 8 : 14)
                }
                .animation(.easeInOut(duration: 0.22), value: st)
            }
        }
    }

    // MARK: - Layout Pieces

    private func header(_ st: CalibrationStatus) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: compact ? 4 : 6) {
                Text(Self.stepLabel(st.step, tier: controller.calibrationTier))
                    .font(.caption.bold())
                    .tracking(0.8)
                    .foregroundStyle(.yellow)
                HStack(spacing: 6) {
                    if let arrow = Self.arrow(for: st.cue) {
                        Image(systemName: arrow).font(.headline)
                    }
                    Text(instruction(st))
                        .font(compact ? .subheadline.bold() : .headline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.white)

                if controller.calibrationTier == .tier2FullCalibration || st.step.rawValue >= CalibrationStep.tpose.rawValue {
                    CalibrationPoseProgressDots(
                        currentStep: st.step,
                        completedSteps: controller.completedSteps,
                        compact: compact
                    )
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))

            Spacer(minLength: 0)

            if !st.isLocked {
                Button {
                    controller.skip()
                } label: {
                    Text("Skip")
                        .font(.subheadline.bold())
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .foregroundStyle(.white)
            }
        }
    }

    private func poseCenterCluster(_ st: CalibrationStatus) -> some View {
        HStack(spacing: compact ? 10 : 16) {
            CalibrationPoseSilhouetteView(
                step: st.step,
                isHolding: st.progress > 0,
                lrSwappedWarning: st.cue == .swapArmsLR
            )
            .frame(width: compact ? 80 : 108, height: compact ? 98 : 134)

            HoldRing(progress: st.progress, locked: st.isLocked, icon: icon(for: st.step))
                .frame(width: compact ? 58 : 78, height: compact ? 58 : 78)
        }
    }

    @ViewBuilder
    private func advisoryRow(_ st: CalibrationStatus) -> some View {
        if st.lightAdvice != .ok {
            advisoryPill(cue: st.lightCue, icon: st.lightCue == .backlit ? "sun.max.trianglebadge.exclamationmark" : "lightbulb")
        } else if st.cameraHeightCue != .none {
            advisoryPill(cue: st.cameraHeightCue, icon: "arrow.up.and.down.circle")
        }
    }

    private func advisoryPill(cue: CalibrationCue, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(cue.spokenText)
                .font(.caption.bold())
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.92), in: Capsule())
    }

    private func footer(_ st: CalibrationStatus) -> some View {
        HStack(spacing: 8) {
            if link.isEnabled {
                HStack(spacing: 4) {
                    Circle().fill(link.connected ? Color.green : Color.gray).frame(width: 6, height: 6)
                    Text(link.connected ? "tuning \(link.tuningHash ?? "defaults")" : "debug link offline")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.55), in: Capsule())
            }
            Spacer(minLength: 0)
            if let dist = st.dancerDistanceM, dist.isFinite, dist > 0 {
                distancePill(distanceM: dist, effectiveMinM: st.effectiveMinDistanceM, cue: st.cue)
            }
        }
    }

    private func distancePill(distanceM: Double, effectiveMinM: Double?, cue: CalibrationCue) -> some View {
        let minM = effectiveMinM ?? controller.tuning.lidarMinDistanceM
        let maxM = controller.tuning.lidarMaxDistanceM
        let inBand = cue != .stepBackDistance && cue != .stepCloserDistance
            && distanceM >= minM - 0.05 && distanceM <= maxM + 0.05
        let targetMin = CalibrationPoseScorers.spokenTargetMinDistanceM(for: minM)
        let label = inBand
            ? String(format: "%.1f m", distanceM)
            : String(format: "%.1f m (%.1f–%.0f m)", distanceM, targetMin, maxM)
        return HStack(spacing: 4) {
            Image(systemName: "sensor.tag.radiowaves.forward.fill")
                .font(.system(size: 10, weight: .bold))
            Text(label)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
        }
        .foregroundStyle(inBand ? Color.green : Color.orange)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.65), in: Capsule())
    }

    /// Gate framing limits drawn on the mirrored preview (raw `x` flipped): safe edges (`[0.04, 0.96]` during lateral
    /// steps, `[safeBoxMinX, safeBoxMaxX]` otherwise), headroom line, and foot line.
    private func framingBox(in rect: CGRect, status st: CalibrationStatus) -> some View {
        let u = controller.tuning
        let isLateralStep = (st.step == .stepLeft || st.step == .stepRight)
        let rawMinX = isLateralStep ? 0.04 : u.safeBoxMinX
        let rawMaxX = isLateralStep ? 0.96 : u.safeBoxMaxX
        let minX = 1.0 - rawMaxX
        let maxX = 1.0 - rawMinX
        let box = CGRect(
            x: rect.minX + minX * rect.width,
            y: rect.minY + u.minNoseY * rect.height,
            width: (maxX - minX) * rect.width,
            height: (u.maxFootY - u.minNoseY) * rect.height
        )
        let ok = Self.isFramingSatisfied(status: st)
        return RoundedRectangle(cornerRadius: 18)
            .stroke(ok ? Color.green : Color.red, style: StrokeStyle(lineWidth: 4, dash: ok ? [] : [10, 6]))
            .frame(width: box.width, height: box.height)
            .position(x: box.midX, y: box.midY)
            .allowsHitTesting(false)
    }

    static func isFramingSatisfied(status st: CalibrationStatus) -> Bool {
        if st.isLocked { return true }
        switch st.cue {
        case .stepIn, .stepBackDistance, .stepCloserDistance,
             .stepBackShowFeet, .showHead, .stepBack, .stepCloser,
             .moveLeft, .moveRight, .stepBackHeadroom, .stepBackLateralRoom:
            return false
        default:
            return st.step != .rest || st.progress > 0 || st.cue == .none || st.cue == .relaxArms || st.cue == .holdStill
        }
    }

    private func instruction(_ st: CalibrationStatus) -> String {
        if st.isLocked {
            if st.skipped { return "Calibration skipped." }
            return controller.calibrationTier == .tier2FullCalibration
                ? CalibrationVoice.studioCalibratedLockedText
                : CalibrationCue.locked.spokenText
        }
        if st.step == .resume {
            return "Checking your setup…"
        }
        if st.step == .plie && st.cue == .bendKneesDeeper && !controller.hasEnteredPlieHold {
            return CalibrationVoice.plieEntryText
        }
        if st.cue != .none {
            return st.cue.spokenText(
                dancerDistanceM: st.dancerDistanceM,
                effectiveMinDistanceM: st.effectiveMinDistanceM
            )
        }
        return Self.holdingPrompt(for: st.step)
    }

    static func holdingPrompt(for step: CalibrationStep) -> String {
        switch step {
        case .resume:
            return "Checking your setup…"
        case .level:
            return "Hold the phone still…"
        case .rest:
            return "Perfect, hold there…"
        case .tpose, .overhead, .asymLR, .armsForward, .plie, .turned45, .stepLeft, .stepRight, .kneeLift:
            return "Good pose—hold still…"
        case .locked:
            return CalibrationCue.locked.spokenText
        }
    }

    private func icon(for step: CalibrationStep) -> String {
        Self.icon(for: step)
    }

    static func icon(for step: CalibrationStep) -> String {
        switch step {
        case .resume, .level:
            return "iphone"
        case .rest:
            return "figure.stand"
        case .tpose:
            return "figure.arms.open"
        case .overhead:
            return "arrow.up.circle"
        case .asymLR:
            return "arrow.up.right.circle"
        case .armsForward:
            return "circle.dotted.circle"
        case .plie:
            return "chevron.down.circle"
        case .turned45:
            return "arrow.triangle.2.circlepath"
        case .stepLeft:
            return "arrow.left.circle"
        case .stepRight:
            return "arrow.right.circle"
        case .kneeLift:
            return "figure.walk"
        case .locked:
            return "checkmark"
        }
    }

    static func stepLabel(_ step: CalibrationStep) -> String {
        stepLabel(step, tier: .tier2FullCalibration)
    }

    static func stepLabel(_ step: CalibrationStep, tier: CalibrationResumeTier) -> String {
        switch step {
        case .resume:
            return "CALIBRATION · QUICK CHECK"
        case .level:
            return tier == .tier1EnvironmentOnly
                ? "STUDIO CHECK · PLACE THE PHONE"
                : "SETUP · PLACE THE PHONE"
        case .rest:
            return tier == .tier2FullCalibration
                ? "POSE 1 OF 9 · RESTING STANCE"
                : "STUDIO CHECK · STAND IN FRAME"
        case .tpose:
            return "POSE 2 OF 9 · T-POSE"
        case .overhead:
            return "POSE 3 OF 9 · ARMS OVERHEAD"
        case .asymLR:
            return "POSE 4 OF 9 · LEFT UP, RIGHT OUT"
        case .armsForward:
            return "POSE 5 OF 9 · ARMS FORWARD"
        case .plie:
            return "POSE 6 OF 9 · GENTLE SQUAT"
        case .turned45:
            return "POSE 7 OF 9 · 45° BODY TURN"
        case .stepLeft:
            return "POSE 8A OF 9 · WIDE STEP LEFT"
        case .stepRight:
            return "POSE 8B OF 9 · WIDE STEP RIGHT"
        case .kneeLift:
            return "POSE 9 OF 9 · KNEE LIFT"
        case .locked:
            return "READY"
        }
    }

    /// Screen arrows for the mirrored preview: "move to your left" points screen-left.
    static func arrow(for cue: CalibrationCue) -> String? {
        switch cue {
        case .moveLeft, .stepLeft:
            return "arrow.left"
        case .moveRight, .stepRight:
            return "arrow.right"
        case .stepBack, .stepBackDistance, .stepBackShowFeet, .showHead, .stepBackHeadroom, .stepBackLateralRoom:
            return "arrow.down.backward.and.arrow.up.forward"
        case .stepCloser, .stepCloserDistance:
            return "arrow.up.forward.and.arrow.down.backward"
        case .reachOverhead:
            return "arrow.up"
        case .bendKneesDeeper:
            return "arrow.down"
        case .turnBody45, .turnLessSideways:
            return "arrow.triangle.2.circlepath"
        case .swapArmsLR:
            return "arrow.left.arrow.right"
        case .liftKnee:
            return "arrow.up.circle"
        default:
            return nil
        }
    }

    /// Aspect-fit rect of the camera image inside the view (matches `.resizeAspect` on the preview layer).
    static func fittedRect(in size: CGSize, imageAspect: Double) -> CGRect {
        guard size.width > 0, size.height > 0, imageAspect > 0 else { return .zero }
        let viewAspect = Double(size.width / size.height)
        if viewAspect > imageAspect {
            let w = size.height * CGFloat(imageAspect)
            return CGRect(x: (size.width - w) / 2, y: 0, width: w, height: size.height)
        }
        let h = size.width / CGFloat(imageAspect)
        return CGRect(x: 0, y: (size.height - h) / 2, width: size.width, height: h)
    }
}

// MARK: - 9-Pose Progress Dots (§2.1, §4.1)

/// Horizontal 9-dot progress indicator mapping `CalibrationStep` onto Poses 1–9 (with Pose 8 split across 8a/8b).
struct CalibrationPoseProgressDots: View {
    let currentStep: CalibrationStep
    var completedSteps: Set<CalibrationStep> = []
    var compact: Bool = false

    static func poseNumber(for step: CalibrationStep) -> Int? {
        switch step {
        case .resume, .level:
            return nil
        case .rest:
            return 1
        case .tpose:
            return 2
        case .overhead:
            return 3
        case .asymLR:
            return 4
        case .armsForward:
            return 5
        case .plie:
            return 6
        case .turned45:
            return 7
        case .stepLeft, .stepRight:
            return 8
        case .kneeLift:
            return 9
        case .locked:
            return 10
        }
    }

    private func isCompleted(poseIndex: Int) -> Bool {
        if currentStep == .locked { return true }
        if let active = Self.poseNumber(for: currentStep), poseIndex < active {
            return true
        }
        switch poseIndex {
        case 1: return completedSteps.contains(.rest)
        case 2: return completedSteps.contains(.tpose)
        case 3: return completedSteps.contains(.overhead)
        case 4: return completedSteps.contains(.asymLR)
        case 5: return completedSteps.contains(.armsForward)
        case 6: return completedSteps.contains(.plie)
        case 7: return completedSteps.contains(.turned45)
        case 8: return completedSteps.contains(.stepLeft) && completedSteps.contains(.stepRight)
        case 9: return completedSteps.contains(.kneeLift)
        default: return false
        }
    }

    var body: some View {
        let activePose = Self.poseNumber(for: currentStep)
        let dotSize: CGFloat = compact ? 7 : 9
        let activeWidth: CGFloat = compact ? 16 : 20
        HStack(spacing: compact ? 5 : 6) {
            ForEach(1...9, id: \.self) { index in
                let done = isCompleted(poseIndex: index)
                let isCurrent = (activePose == index)
                if isCurrent {
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.yellow.opacity(index == 8 && currentStep == .stepLeft ? 0.35 : 1.0))
                            .frame(width: activeWidth, height: dotSize)
                        if index == 8 && currentStep == .stepLeft {
                            Capsule()
                                .fill(Color.yellow)
                                .frame(width: activeWidth * 0.55, height: dotSize)
                        }
                    }
                } else {
                    Circle()
                        .fill(done ? Color.green : Color.white.opacity(0.28))
                        .frame(width: dotSize, height: dotSize)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(progressAccessibilityLabel(activePose: activePose))
    }

    private func progressAccessibilityLabel(activePose: Int?) -> String {
        if currentStep == .locked { return "All 9 calibration poses complete" }
        guard let activePose, (1...9).contains(activePose) else {
            return "Phone setup"
        }
        return "Pose \(activePose) of 9"
    }
}

// MARK: - 9-Pose Target Mannequin Silhouettes (§2.2, §4.1)

/// High-contrast mirrored target silhouette for Poses 1–9 (dancer's left side on screen-left, matching mirrored preview).
struct CalibrationPoseSilhouetteView: View {
    let step: CalibrationStep
    var isHolding: Bool = false
    var lrSwappedWarning: Bool = false

    fileprivate struct SilhouetteJoints {
        var head: CGPoint
        var leftShoulder: CGPoint
        var rightShoulder: CGPoint
        var leftElbow: CGPoint
        var rightElbow: CGPoint
        var leftWrist: CGPoint
        var rightWrist: CGPoint
        var leftHip: CGPoint
        var rightHip: CGPoint
        var leftKnee: CGPoint
        var rightKnee: CGPoint
        var leftAnkle: CGPoint
        var rightAnkle: CGPoint
        var foreshortenedHands: Bool = false
        var showLRBadges: Bool = false
        var stepDirection: Int = 0 // -1 left, +1 right
        var showTurnArc: Bool = false
    }

    var body: some View {
        let strokeColor: Color = lrSwappedWarning ? .orange : (isHolding ? .green : .cyan)
        ZStack {
            Canvas { ctx, size in
                let spec = Self.joints(for: step)
                func pt(_ norm: CGPoint) -> CGPoint {
                    CGPoint(x: norm.x * size.width, y: norm.y * size.height)
                }

                // Reference center guide for lateral step poses (8a / 8b).
                if spec.stepDirection != 0 {
                    var centerGuide = Path()
                    centerGuide.move(to: CGPoint(x: size.width * 0.5, y: size.height * 0.14))
                    centerGuide.addLine(to: CGPoint(x: size.width * 0.5, y: size.height * 0.90))
                    ctx.stroke(
                        centerGuide,
                        with: .color(.white.opacity(0.25)),
                        style: StrokeStyle(lineWidth: 1.5, dash: [4, 4])
                    )

                    let arrowY = size.height * 0.93
                    let fromX = size.width * 0.50
                    let toX = size.width * (spec.stepDirection < 0 ? 0.24 : 0.76)
                    var arrow = Path()
                    arrow.move(to: CGPoint(x: fromX, y: arrowY))
                    arrow.addLine(to: CGPoint(x: toX, y: arrowY))
                    let tipDX: CGFloat = spec.stepDirection < 0 ? 6 : -6
                    arrow.move(to: CGPoint(x: toX + tipDX, y: arrowY - 4))
                    arrow.addLine(to: CGPoint(x: toX, y: arrowY))
                    arrow.addLine(to: CGPoint(x: toX + tipDX, y: arrowY + 4))
                    ctx.stroke(arrow, with: .color(.yellow), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                }

                // Rotation arc below feet for 45° oblique turn (Pose 7).
                if spec.showTurnArc {
                    var arc = Path()
                    let c = CGPoint(x: size.width * 0.5, y: size.height * 0.91)
                    arc.addArc(
                        center: c,
                        radius: size.width * 0.22,
                        startAngle: .degrees(200),
                        endAngle: .degrees(340),
                        clockwise: false
                    )
                    ctx.stroke(arc, with: .color(.yellow.opacity(0.85)), style: StrokeStyle(lineWidth: 2.0, lineCap: .round))
                }

                let lineW = max(3.0, min(size.width, size.height) * 0.048)
                let limbStyle = StrokeStyle(lineWidth: lineW, lineCap: .round, lineJoin: .round)

                let ls = pt(spec.leftShoulder)
                let rs = pt(spec.rightShoulder)
                let lh = pt(spec.leftHip)
                let rh = pt(spec.rightHip)
                let midShoulder = CGPoint(x: (ls.x + rs.x) * 0.5, y: (ls.y + rs.y) * 0.5)
                let midHip = CGPoint(x: (lh.x + rh.x) * 0.5, y: (lh.y + rh.y) * 0.5)

                var bodyPath = Path()
                // Torso + shoulders + hips
                bodyPath.move(to: ls)
                bodyPath.addLine(to: rs)
                bodyPath.move(to: midShoulder)
                bodyPath.addLine(to: midHip)
                bodyPath.move(to: lh)
                bodyPath.addLine(to: rh)
                // Arms
                bodyPath.move(to: ls)
                bodyPath.addLine(to: pt(spec.leftElbow))
                bodyPath.addLine(to: pt(spec.leftWrist))
                bodyPath.move(to: rs)
                bodyPath.addLine(to: pt(spec.rightElbow))
                bodyPath.addLine(to: pt(spec.rightWrist))
                // Legs
                bodyPath.move(to: lh)
                bodyPath.addLine(to: pt(spec.leftKnee))
                bodyPath.addLine(to: pt(spec.leftAnkle))
                bodyPath.move(to: rh)
                bodyPath.addLine(to: pt(spec.rightKnee))
                bodyPath.addLine(to: pt(spec.rightAnkle))

                ctx.stroke(bodyPath, with: .color(strokeColor), style: limbStyle)

                // Head circle
                let headCenter = pt(spec.head)
                let headRadius = max(6.0, min(size.width, size.height) * 0.085)
                let headRect = CGRect(
                    x: headCenter.x - headRadius,
                    y: headCenter.y - headRadius,
                    width: headRadius * 2,
                    height: headRadius * 2
                )
                ctx.fill(Path(ellipseIn: headRect), with: .color(strokeColor))

                // Foreshortened hand depth rings for Pose 5 (`.armsForward`).
                if spec.foreshortenedHands {
                    for wristNorm in [spec.leftWrist, spec.rightWrist] {
                        let wp = pt(wristNorm)
                        let rOuter = headRadius * 0.95
                        let rInner = headRadius * 0.45
                        let outerRect = CGRect(x: wp.x - rOuter, y: wp.y - rOuter, width: rOuter * 2, height: rOuter * 2)
                        let innerRect = CGRect(x: wp.x - rInner, y: wp.y - rInner, width: rInner * 2, height: rInner * 2)
                        ctx.stroke(Path(ellipseIn: outerRect), with: .color(.yellow), lineWidth: 2.0)
                        ctx.fill(Path(ellipseIn: innerRect), with: .color(.yellow))
                    }
                }
            }

            if step == .asymLR {
                HStack {
                    Text("L")
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .foregroundStyle(.yellow)
                        .padding(3)
                    Spacer()
                    Text("R")
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .foregroundStyle(.yellow)
                        .padding(3)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .padding(6)
        .background(Color.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(strokeColor.opacity(0.65), lineWidth: 1.5)
        )
        .allowsHitTesting(false)
    }

    fileprivate static func joints(for step: CalibrationStep) -> SilhouetteJoints {
        switch step {
        case .resume, .level, .rest, .locked:
            return SilhouetteJoints(
                head: CGPoint(x: 0.50, y: 0.19),
                leftShoulder: CGPoint(x: 0.38, y: 0.32),
                rightShoulder: CGPoint(x: 0.62, y: 0.32),
                leftElbow: CGPoint(x: 0.35, y: 0.45),
                rightElbow: CGPoint(x: 0.65, y: 0.45),
                leftWrist: CGPoint(x: 0.36, y: 0.57),
                rightWrist: CGPoint(x: 0.64, y: 0.57),
                leftHip: CGPoint(x: 0.42, y: 0.54),
                rightHip: CGPoint(x: 0.58, y: 0.54),
                leftKnee: CGPoint(x: 0.42, y: 0.71),
                rightKnee: CGPoint(x: 0.58, y: 0.71),
                leftAnkle: CGPoint(x: 0.41, y: 0.87),
                rightAnkle: CGPoint(x: 0.59, y: 0.87)
            )
        case .tpose:
            return SilhouetteJoints(
                head: CGPoint(x: 0.50, y: 0.19),
                leftShoulder: CGPoint(x: 0.39, y: 0.32),
                rightShoulder: CGPoint(x: 0.61, y: 0.32),
                leftElbow: CGPoint(x: 0.24, y: 0.32),
                rightElbow: CGPoint(x: 0.76, y: 0.32),
                leftWrist: CGPoint(x: 0.09, y: 0.32),
                rightWrist: CGPoint(x: 0.91, y: 0.32),
                leftHip: CGPoint(x: 0.43, y: 0.54),
                rightHip: CGPoint(x: 0.57, y: 0.54),
                leftKnee: CGPoint(x: 0.42, y: 0.71),
                rightKnee: CGPoint(x: 0.58, y: 0.71),
                leftAnkle: CGPoint(x: 0.41, y: 0.87),
                rightAnkle: CGPoint(x: 0.59, y: 0.87)
            )
        case .overhead:
            return SilhouetteJoints(
                head: CGPoint(x: 0.50, y: 0.23),
                leftShoulder: CGPoint(x: 0.39, y: 0.35),
                rightShoulder: CGPoint(x: 0.61, y: 0.35),
                leftElbow: CGPoint(x: 0.36, y: 0.20),
                rightElbow: CGPoint(x: 0.64, y: 0.20),
                leftWrist: CGPoint(x: 0.37, y: 0.07),
                rightWrist: CGPoint(x: 0.63, y: 0.07),
                leftHip: CGPoint(x: 0.43, y: 0.56),
                rightHip: CGPoint(x: 0.57, y: 0.56),
                leftKnee: CGPoint(x: 0.42, y: 0.72),
                rightKnee: CGPoint(x: 0.58, y: 0.72),
                leftAnkle: CGPoint(x: 0.41, y: 0.88),
                rightAnkle: CGPoint(x: 0.59, y: 0.88)
            )
        case .asymLR:
            return SilhouetteJoints(
                head: CGPoint(x: 0.50, y: 0.23),
                leftShoulder: CGPoint(x: 0.39, y: 0.35),
                rightShoulder: CGPoint(x: 0.61, y: 0.35),
                leftElbow: CGPoint(x: 0.36, y: 0.20),
                rightElbow: CGPoint(x: 0.76, y: 0.35),
                leftWrist: CGPoint(x: 0.37, y: 0.07),
                rightWrist: CGPoint(x: 0.91, y: 0.35),
                leftHip: CGPoint(x: 0.43, y: 0.56),
                rightHip: CGPoint(x: 0.57, y: 0.56),
                leftKnee: CGPoint(x: 0.42, y: 0.72),
                rightKnee: CGPoint(x: 0.58, y: 0.72),
                leftAnkle: CGPoint(x: 0.41, y: 0.88),
                rightAnkle: CGPoint(x: 0.59, y: 0.88),
                showLRBadges: true
            )
        case .armsForward:
            return SilhouetteJoints(
                head: CGPoint(x: 0.50, y: 0.19),
                leftShoulder: CGPoint(x: 0.37, y: 0.33),
                rightShoulder: CGPoint(x: 0.63, y: 0.33),
                leftElbow: CGPoint(x: 0.38, y: 0.36),
                rightElbow: CGPoint(x: 0.62, y: 0.36),
                leftWrist: CGPoint(x: 0.39, y: 0.38),
                rightWrist: CGPoint(x: 0.61, y: 0.38),
                leftHip: CGPoint(x: 0.43, y: 0.55),
                rightHip: CGPoint(x: 0.57, y: 0.55),
                leftKnee: CGPoint(x: 0.42, y: 0.72),
                rightKnee: CGPoint(x: 0.58, y: 0.72),
                leftAnkle: CGPoint(x: 0.41, y: 0.88),
                rightAnkle: CGPoint(x: 0.59, y: 0.88),
                foreshortenedHands: true
            )
        case .plie:
            return SilhouetteJoints(
                head: CGPoint(x: 0.50, y: 0.25),
                leftShoulder: CGPoint(x: 0.39, y: 0.38),
                rightShoulder: CGPoint(x: 0.61, y: 0.38),
                leftElbow: CGPoint(x: 0.25, y: 0.38),
                rightElbow: CGPoint(x: 0.75, y: 0.38),
                leftWrist: CGPoint(x: 0.11, y: 0.38),
                rightWrist: CGPoint(x: 0.89, y: 0.38),
                leftHip: CGPoint(x: 0.42, y: 0.60),
                rightHip: CGPoint(x: 0.58, y: 0.60),
                leftKnee: CGPoint(x: 0.31, y: 0.73),
                rightKnee: CGPoint(x: 0.69, y: 0.73),
                leftAnkle: CGPoint(x: 0.38, y: 0.88),
                rightAnkle: CGPoint(x: 0.62, y: 0.88)
            )
        case .turned45:
            return SilhouetteJoints(
                head: CGPoint(x: 0.50, y: 0.19),
                leftShoulder: CGPoint(x: 0.43, y: 0.32),
                rightShoulder: CGPoint(x: 0.57, y: 0.34),
                leftElbow: CGPoint(x: 0.29, y: 0.31),
                rightElbow: CGPoint(x: 0.70, y: 0.35),
                leftWrist: CGPoint(x: 0.16, y: 0.30),
                rightWrist: CGPoint(x: 0.83, y: 0.36),
                leftHip: CGPoint(x: 0.45, y: 0.54),
                rightHip: CGPoint(x: 0.55, y: 0.55),
                leftKnee: CGPoint(x: 0.44, y: 0.70),
                rightKnee: CGPoint(x: 0.56, y: 0.71),
                leftAnkle: CGPoint(x: 0.43, y: 0.85),
                rightAnkle: CGPoint(x: 0.57, y: 0.86),
                showTurnArc: true
            )
        case .stepLeft:
            return SilhouetteJoints(
                head: CGPoint(x: 0.36, y: 0.19),
                leftShoulder: CGPoint(x: 0.25, y: 0.32),
                rightShoulder: CGPoint(x: 0.47, y: 0.32),
                leftElbow: CGPoint(x: 0.20, y: 0.44),
                rightElbow: CGPoint(x: 0.52, y: 0.44),
                leftWrist: CGPoint(x: 0.22, y: 0.55),
                rightWrist: CGPoint(x: 0.50, y: 0.55),
                leftHip: CGPoint(x: 0.29, y: 0.54),
                rightHip: CGPoint(x: 0.43, y: 0.54),
                leftKnee: CGPoint(x: 0.24, y: 0.70),
                rightKnee: CGPoint(x: 0.48, y: 0.70),
                leftAnkle: CGPoint(x: 0.21, y: 0.85),
                rightAnkle: CGPoint(x: 0.52, y: 0.85),
                stepDirection: -1
            )
        case .stepRight:
            return SilhouetteJoints(
                head: CGPoint(x: 0.64, y: 0.19),
                leftShoulder: CGPoint(x: 0.53, y: 0.32),
                rightShoulder: CGPoint(x: 0.75, y: 0.32),
                leftElbow: CGPoint(x: 0.48, y: 0.44),
                rightElbow: CGPoint(x: 0.80, y: 0.44),
                leftWrist: CGPoint(x: 0.50, y: 0.55),
                rightWrist: CGPoint(x: 0.78, y: 0.55),
                leftHip: CGPoint(x: 0.57, y: 0.54),
                rightHip: CGPoint(x: 0.71, y: 0.54),
                leftKnee: CGPoint(x: 0.52, y: 0.70),
                rightKnee: CGPoint(x: 0.76, y: 0.70),
                leftAnkle: CGPoint(x: 0.48, y: 0.85),
                rightAnkle: CGPoint(x: 0.79, y: 0.85),
                stepDirection: 1
            )
        case .kneeLift:
            return SilhouetteJoints(
                head: CGPoint(x: 0.52, y: 0.19),
                leftShoulder: CGPoint(x: 0.40, y: 0.32),
                rightShoulder: CGPoint(x: 0.64, y: 0.32),
                leftElbow: CGPoint(x: 0.28, y: 0.36),
                rightElbow: CGPoint(x: 0.76, y: 0.36),
                leftWrist: CGPoint(x: 0.20, y: 0.41),
                rightWrist: CGPoint(x: 0.84, y: 0.41),
                leftHip: CGPoint(x: 0.45, y: 0.54),
                rightHip: CGPoint(x: 0.59, y: 0.54),
                leftKnee: CGPoint(x: 0.32, y: 0.50),
                rightKnee: CGPoint(x: 0.59, y: 0.71),
                leftAnkle: CGPoint(x: 0.35, y: 0.67),
                rightAnkle: CGPoint(x: 0.59, y: 0.88)
            )
        }
    }
}

/// Bubble-level line (stays level with the world as the phone rolls) and a tilt arc with the allowed window.
private struct LevelIndicator: View {
    let rollDeg: Double?
    let tiltBackDeg: Double?
    let tuning: CalibrationTuning

    private static let arcMin = -30.0
    private static let arcMax = 45.0

    var body: some View {
        let roll = rollDeg ?? 0
        let level = abs(roll) <= tuning.rollEnterDeg
        let tilt = tiltBackDeg ?? 0
        let tiltOK = tilt >= tuning.tiltBackMinDeg && tilt <= tuning.tiltBackMaxDeg
        VStack(spacing: 6) {
            ZStack {
                Rectangle()
                    .fill(Color.white.opacity(0.35))
                    .frame(height: 2)
                Capsule()
                    .fill(level ? Color.green : Color.red)
                    .frame(height: 5)
                    .rotationEffect(.degrees(-roll))
                Text(rollDeg.map { String(format: "%+.0f°", $0) } ?? "–")
                    .font(.caption2.monospacedDigit().bold())
                    .foregroundStyle(.white)
                    .offset(y: 16)
            }
            .frame(height: 40)

            Canvas { ctx, size in
                let center = CGPoint(x: size.width / 2, y: size.height - 6)
                let r = min(size.width / 2, size.height) - 8
                func screenAngle(_ deg: Double) -> Angle {
                    // Map tilt (deg) onto a 150° arc opening upwards; more tilt-back = further right.
                    let f = (deg - Self.arcMin) / (Self.arcMax - Self.arcMin)
                    return .degrees(-165 + 150 * min(1, max(0, f)))
                }
                var full = Path()
                full.addArc(
                    center: center,
                    radius: r,
                    startAngle: screenAngle(Self.arcMin),
                    endAngle: screenAngle(Self.arcMax),
                    clockwise: false
                )
                ctx.stroke(full, with: .color(.white.opacity(0.3)), lineWidth: 6)
                var window = Path()
                window.addArc(
                    center: center,
                    radius: r,
                    startAngle: screenAngle(tuning.tiltBackMinDeg),
                    endAngle: screenAngle(tuning.tiltBackMaxDeg),
                    clockwise: false
                )
                ctx.stroke(window, with: .color(.green.opacity(0.8)), lineWidth: 6)
                if tiltBackDeg != nil {
                    let a = screenAngle(tilt).radians
                    var needle = Path()
                    needle.move(to: center)
                    needle.addLine(to: CGPoint(x: center.x + cos(a) * (r + 4), y: center.y + sin(a) * (r + 4)))
                    ctx.stroke(needle, with: .color(tiltOK ? .green : .red), lineWidth: 3)
                }
            }
            Text(tiltBackDeg.map { String(format: "tilt %+.0f°", $0) } ?? "tilt –")
                .font(.caption2.monospacedDigit().bold())
                .foregroundStyle(.white)
        }
        .padding(8)
        .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Hold progress ring (0...1), green check once locked.
private struct HoldRing: View {
    let progress: Double
    let locked: Bool
    let icon: String

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.25), lineWidth: 6)
            Circle()
                .trim(from: 0, to: CGFloat(min(1, max(0, progress))))
                .stroke(Color.green, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: locked ? "checkmark" : icon)
                .font(.title3.bold())
                .foregroundStyle(locked ? .green : .white)
        }
        .padding(4)
        .background(Color.black.opacity(0.45), in: Circle())
    }
}
