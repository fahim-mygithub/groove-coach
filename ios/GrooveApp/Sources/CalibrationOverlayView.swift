import AVFoundation
import Combine
import CoreGraphics
import GrooveCore
import SwiftUI

// MARK: - Controller

/// Runs one pre-take calibration (spec: docs/research/2026-11-18-calibration-research.md) for a screen: feeds
/// `CalibrationGate` from the motion stream (30 Hz), the live pose stream (camera analysis queue) and a 2 Hz light
/// sample; drives the voice, the overlay and the Debug Link; reports the outcome once locked or skipped.
@MainActor
final class CalibrationController: ObservableObject {
    struct Outcome {
        /// The locked profile; nil when skipped (`calibration_frames = nil`).
        let profile: CalibrationProfile?
        /// Gravity locked by the gate (the latest reading when skipped), nil if no motion reading arrived.
        let gravity: [Double]?
        let skipped: Bool
        let resumed: Bool
    }

    /// The gate's status while a calibration is shown; nil when none is running.
    @Published private(set) var status: CalibrationStatus?
    @Published private(set) var rollDeg: Double?
    @Published private(set) var tiltBackDeg: Double?
    @Published private(set) var tuning: CalibrationTuning = .defaults

    /// The last locked profile on any screen: step 0 resumes from it when the phone has not moved.
    static var lastProfile: CalibrationProfile?

    let sensors = CalibrationSensors()
    private let screen: String
    private let voice = CalibrationVoice()
    private var gate = CalibrationGate()
    private weak var camera: PracticeCamera?
    private var onFinish: ((Outcome) -> Void)?
    private var running = false
    private var linkSession = false
    private var tuningSub: AnyCancellable?

    init(screen: String) {
        self.screen = screen
        sensors.onMotion = { [weak self] m in
            // CMMotionManager delivers on the main queue.
            MainActor.assumeIsolated { self?.ingest(motion: m) }
        }
    }

    var isRunning: Bool { running }

    func startSensors() { sensors.startMotion() }

    func stopSensors() {
        cancel()
        sensors.stopMotion()
    }

    func currentGravity() -> [Double] { sensors.currentGravity() }

    /// Starts a calibration on `camera`; `onFinish` runs once, on lock or Skip (not on `cancel()`).
    func begin(camera: PracticeCamera, onFinish: @escaping (Outcome) -> Void) {
        cancel()
        sensors.startMotion()
        self.camera = camera
        self.onFinish = onFinish
        running = true

        let link = DebugLink.shared
        link.beginSession()
        linkSession = true
        let t = link.tuning ?? .defaults
        tuning = t
        gate = CalibrationGate(tuning: t, resume: Self.lastProfile)
        rollDeg = nil
        tiltBackDeg = nil
        status = gate.status
        voice.reset()
        voice.update(cue: gate.cue)
        tuningSub = link.$tuning.dropFirst().sink { [weak self] newValue in
            MainActor.assumeIsolated { self?.apply(tuning: newValue ?? .defaults) }
        }

        let sampler = CalibrationSampler()
        camera.startCalibration { [weak self, weak camera] sample in
            // Camera analysis queue: read light and the debug snapshot here, while the buffer is valid.
            let pose = CalibrationPoseSample(timestamp: sample.time, landmarks: sample.landmarks, frame: sample.frame)
            let light = sampler.lightIfDue(sample, device: camera?.captureDevice)
            let snapshot = sampler.snapshotIfDue(sample)
            let points = sample.landmarks
            Task { @MainActor in
                self?.ingest(pose: pose, landmarks: points, light: light, snapshot: snapshot)
            }
        }
    }

    /// The Skip button: lock now without calibration frames.
    func skip() {
        guard running else { return }
        gate.skip()
        publish()
    }

    /// Leaves calibration without an outcome (take aborted, screen left). Safe to call any time.
    func cancel() {
        let wasRunning = running
        endStreams()
        onFinish = nil
        status = nil
        if wasRunning { voice.stop() }
    }

    private func endStreams() {
        running = false
        camera?.stopCalibration()
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

    // MARK: Streams

    private func ingest(motion m: CalibrationMotionSample) {
        guard running else { return }
        let (roll, tilt) = CalibrationGate.angles(gravity: m.gravity)
        if rollDeg.map({ abs($0 - roll) >= 0.3 }) ?? true { rollDeg = roll }
        if tiltBackDeg.map({ abs($0 - tilt) >= 0.3 }) ?? true { tiltBackDeg = tilt }
        gate.update(motion: m)
        publish()
    }

    private func ingest(pose: CalibrationPoseSample, landmarks: [CalibrationLandmark],
                        light: CalibrationLightSample?, snapshot: CGImage?) {
        guard running else { return }
        gate.update(pose: pose)
        if let light { gate.update(light: light) }
        if let snapshot {
            let st = gate.status
            let framingOK = gate.telemetry().framingOK ?? false
            DebugLink.shared.sendFrame(image: snapshot, landmarks: landmarks, tuning: gate.tuning,
                                       framingOK: framingOK, label: "\(st.step.name) \(st.cue.rawValue)")
        }
        publish()
    }

    private func publish() {
        let st = gate.status
        if st != status { status = st }
        voice.update(cue: st.cue)
        voice.update(lightCue: st.lightCue, blockingCue: st.cue)
        let gate = self.gate
        DebugLink.shared.offerTelemetry({ gate.telemetry() }, extra: ["screen": screen])
        if st.isLocked { finish() }
    }

    private func finish() {
        guard running else { return }
        let outcome = Outcome(profile: gate.lockedProfile, gravity: gate.lockedGravity,
                              skipped: gate.skipped, resumed: gate.resumed)
        if let p = gate.lockedProfile { Self.lastProfile = p }
        DebugLink.shared.sendTelemetry(gate.telemetry(), kind: "calibration_end", extra: ["screen": screen])
        endStreams()
        let callback = onFinish
        onFinish = nil
        callback?(outcome)
    }
}

/// Per-calibration throttles, confined to the camera analysis queue.
final class CalibrationSampler: @unchecked Sendable {
    static let lightInterval = 0.5

    private var lastLight = -Double.infinity
    private var lastSnapshot = -Double.infinity

    func lightIfDue(_ s: CalibrationCameraSample, device: AVCaptureDevice?) -> CalibrationLightSample? {
        guard s.time - lastLight >= Self.lightInterval else { return nil }
        lastLight = s.time
        return CalibrationSensors.lightSample(s.pixelBuffer, device: device,
                                              torso: CalibrationSensors.torsoRect(s.landmarks))
    }

    func snapshotIfDue(_ s: CalibrationCameraSample) -> CGImage? {
        guard DebugLinkSettings.isEnabled, s.time - lastSnapshot >= DebugLinkSettings.frameInterval else { return nil }
        lastSnapshot = s.time
        return DebugLinkImaging.snapshot(s.pixelBuffer)
    }
}

// MARK: - Overlay

/// Calibration HUD over the (mirrored) camera preview: step label and instruction, level line + tilt arc (step 1),
/// a framing box that turns red -> green (steps 2 and 4), an amber light pill, the hold ring, Skip, and a
/// "tuning <hash6>" badge while the Debug Link is connected.
struct CalibrationOverlayView: View {
    @ObservedObject var controller: CalibrationController
    @ObservedObject private var link = DebugLink.shared
    /// width / height of the camera image (the preview is aspect-fit).
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
                    if st.step == .frame || st.step == .tpose || st.step == .locked {
                        framingBox(in: rect, status: st)
                    }
                    VStack(spacing: compact ? 6 : 10) {
                        header(st)
                        Spacer(minLength: 0)
                        if st.step == .level {
                            LevelIndicator(rollDeg: controller.rollDeg, tiltBackDeg: controller.tiltBackDeg,
                                           tuning: controller.tuning)
                                .frame(width: compact ? 150 : 200, height: compact ? 110 : 150)
                        }
                        if st.progress > 0 || st.step == .tpose || st.isLocked {
                            HoldRing(progress: st.progress, locked: st.isLocked, icon: icon(for: st.step))
                                .frame(width: compact ? 56 : 76, height: compact ? 56 : 76)
                        }
                        if st.lightAdvice != .ok {
                            lightPill(st.lightCue)
                        }
                        footer
                    }
                    .padding(compact ? 8 : 14)
                }
                .animation(.easeInOut(duration: 0.25), value: st)
            }
        }
    }

    // MARK: Pieces

    private func header(_ st: CalibrationStatus) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.stepLabel(st.step))
                    .font(.caption.bold())
                    .tracking(1)
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
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
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

    private var footer: some View {
        HStack {
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
        }
    }

    private func lightPill(_ cue: CalibrationCue) -> some View {
        HStack(spacing: 6) {
            Image(systemName: cue == .backlit ? "sun.max.trianglebadge.exclamationmark" : "lightbulb")
            Text(cue.spokenText)
                .font(.caption.bold())
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.92), in: Capsule())
    }

    /// The gate's framing limits drawn on the mirrored preview (raw x flipped): left/right safe edges, the headroom
    /// line and the foot line.
    private func framingBox(in rect: CGRect, status st: CalibrationStatus) -> some View {
        let u = controller.tuning
        let minX = 1.0 - u.safeBoxMaxX
        let maxX = 1.0 - u.safeBoxMinX
        let box = CGRect(x: rect.minX + minX * rect.width,
                         y: rect.minY + u.minNoseY * rect.height,
                         width: (maxX - minX) * rect.width,
                         height: (u.maxFootY - u.minNoseY) * rect.height)
        let ok = st.step == .tpose || st.isLocked || (st.step == .frame && st.cue == .none)
        return RoundedRectangle(cornerRadius: 18)
            .stroke(ok ? Color.green : Color.red, style: StrokeStyle(lineWidth: 4, dash: ok ? [] : [10, 6]))
            .frame(width: box.width, height: box.height)
            .position(x: box.midX, y: box.midY)
            .allowsHitTesting(false)
    }

    private func instruction(_ st: CalibrationStatus) -> String {
        if st.isLocked { return st.skipped ? "Calibration skipped." : CalibrationCue.locked.spokenText }
        if st.step == .resume { return "Checking your setup…" }
        if st.cue != .none { return st.cue.spokenText }
        switch st.step {
        case .level: return "Hold the phone still…"
        case .frame: return "Perfect, hold there…"
        default: return "Hold still…"
        }
    }

    private func icon(for step: CalibrationStep) -> String {
        switch step {
        case .level, .resume: return "iphone"
        case .frame: return "figure.stand"
        case .tpose: return "figure.arms.open"
        case .locked: return "checkmark"
        }
    }

    static func stepLabel(_ step: CalibrationStep) -> String {
        switch step {
        case .resume: return "CALIBRATION"
        case .level: return "STEP 1 OF 3 · PLACE THE PHONE"
        case .frame: return "STEP 2 OF 3 · FULL BODY IN FRAME"
        case .tpose: return "STEP 3 OF 3 · T-POSE"
        case .locked: return "READY"
        }
    }

    /// Screen arrows for the mirrored preview: "move to your left" is screen-left.
    static func arrow(for cue: CalibrationCue) -> String? {
        switch cue {
        case .moveLeft: return "arrow.left"
        case .moveRight: return "arrow.right"
        case .stepBack, .stepBackShowFeet, .showHead: return "arrow.down.backward.and.arrow.up.forward"
        case .stepCloser: return "arrow.up.forward.and.arrow.down.backward"
        default: return nil
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
                full.addArc(center: center, radius: r, startAngle: screenAngle(Self.arcMin),
                            endAngle: screenAngle(Self.arcMax), clockwise: false)
                ctx.stroke(full, with: .color(.white.opacity(0.3)), lineWidth: 6)
                var window = Path()
                window.addArc(center: center, radius: r, startAngle: screenAngle(tuning.tiltBackMinDeg),
                              endAngle: screenAngle(tuning.tiltBackMaxDeg), clockwise: false)
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
