import AVFoundation
import CoreMotion
import GrooveCore
import SwiftUI
import UIKit

/// Live practice loop: calibration (9-pose studio + LiDAR / 3-tier resume; skippable) -> count-in clicks -> record a take ->
/// score it against the selected reference move.
/// Shared `CoachingStageCoordinator` mounts `TVCoachingStageView` over AirPlay, switches `CameraMode` (`rearLiDAR` with TV,
/// `frontSelfView` fallback + manual toggle), routes hands-free `CoachingCommand`s via `GestureRouter`, and handles AirPlay drops.
@MainActor
final class PracticeViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle, calibrating, countIn, recording, analyzing, results, paused

        var coachingPhase: CoachingPhase {
            switch self {
            case .idle:
                return .idle
            case .calibrating:
                return .calibrating
            case .countIn:
                return .countIn
            case .recording:
                return .recording
            case .analyzing:
                return .analyzing
            case .results:
                return .results
            case .paused:
                return .paused
            }
        }
    }

    @Published var phase: Phase = .idle {
        didSet {
            syncPhaseToCoordinator()
        }
    }
    @Published var selectedMove: String = "" {
        didSet {
            syncSelectedMoveToStage()
        }
    }
    @Published var mirrorTeacher = true {
        didSet {
            syncMirrorToStage()
        }
    }
    @Published var toast: String?
    @Published var status = "Pick a reference move, then clap, raise both hands, or tap Start." {
        didSet {
            coordinator.setStatusMessage(status)
        }
    }
    @Published var result: GrooveScoringEngine.AttemptScoreResult?
    @Published var resultPose: [String: CGPoint] = [:]
    @Published var countInBeatsLeft = 0 {
        didSet {
            coordinator.updateStage(countInBeatsLeft: countInBeatsLeft)
        }
    }

    let camera = PracticeCamera()
    /// Pre-take studio & body calibration; also owns this screen's motion stream (`currentCameraGravity()`).
    let calibration = CalibrationController(screen: "practice")
    /// Shared TV stage, camera-mode, AirPlay-drop, `GestureRouter`, and `CalibrationProfileStore` coordinator.
    let coordinator = CoachingStageCoordinator(host: .practice)
    weak var library: GrooveLibrary?
    private let metronome = Metronome()
    /// Skip is remembered for the rest of this visit (unless "Recalibrate Studio" is requested), so hands-free retakes go straight to count-in.
    private var calibrationSkipped = false
    private var takeTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var takeCounter = 0

    static let countInBeats = 4

    init() {
        camera.onGesture = { [weak self] command in
            Task { @MainActor [weak self] in
                self?.handle(command)
            }
        }
        coordinator.onCommand = { [weak self] command in
            self?.handle(command, fromCoordinator: true)
        }
        coordinator.onAirPlayDroppedInPhase = { [weak self] droppedPhase in
            self?.handleAirPlayDropped(in: droppedPhase)
        }
        coordinator.onAirPlayReconnected = { [weak self] in
            self?.handleAirPlayReconnected()
        }
        coordinator.onRecalibrateStudioRequested = { [weak self] in
            self?.handleRecalibrateStudioRequested()
        }
        coordinator.updateStage(
            title: "Practice",
            playbackRate: 1.0,
            isTeacherMirrored: mirrorTeacher,
            hasTeacherVideo: false,
            statusMessage: status
        )
    }

    func onAppear(library: GrooveLibrary) {
        self.library = library
        UIApplication.shared.isIdleTimerDisabled = true
        if selectedMove.isEmpty || library.references[selectedMove] == nil {
            selectedMove = library.references.keys.sorted().first ?? ""
        }
        calibrationSkipped = false
        coordinator.attach(camera: camera, calibration: calibration, host: .practice)
        syncSelectedMoveToStage()
        syncPhaseToCoordinator()
        calibration.startSensors()
        Task { @MainActor [weak self] in
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard let self, self.coordinator.isAttached else { return }
            if granted {
                self.camera.start()
            } else {
                self.status = "Camera access is off: enable it in Settings > Groove Coach."
            }
        }
    }

    func onDisappear() {
        UIApplication.shared.isIdleTimerDisabled = false
        abortTake(to: .idle)
        calibration.stopSensors()
        coordinator.detach()
        camera.stop()
    }

    // MARK: - Stage & Coordinator Synchronization

    var stageTitle: String {
        selectedMove.isEmpty ? "Practice" : selectedMove
    }

    private var hasAvailableMoves: Bool {
        !(library?.references.isEmpty ?? true)
    }

    private func syncPhaseToCoordinator() {
        coordinator.setPhase(
            phase.coachingPhase,
            passed: result?.passed,
            nextUnlocked: hasAvailableMoves
        )
    }

    private func syncMirrorToStage() {
        coordinator.updateStage(isTeacherMirrored: mirrorTeacher)
        if let library, let reference = library.references[selectedMove], let firstBeat = reference.beat_times.first {
            coordinator.updateStage(
                referencePose: Self.displayPose(take: reference, at: firstBeat, mirrored: mirrorTeacher)
            )
        }
    }

    private func syncSelectedMoveToStage() {
        guard let library, let reference = library.references[selectedMove] else {
            coordinator.updateStage(
                title: stageTitle,
                subtitle: "Select a reference move",
                playbackRate: 1.0,
                isTeacherMirrored: mirrorTeacher,
                hasTeacherVideo: false,
                referencePose: [:],
                nextUnlocked: hasAvailableMoves
            )
            return
        }
        let pose: [String: CGPoint]
        if let firstBeat = reference.beat_times.first {
            pose = Self.displayPose(take: reference, at: firstBeat, mirrored: mirrorTeacher)
        } else {
            pose = [:]
        }
        coordinator.updateStage(
            title: selectedMove,
            subtitle: "\(Int(reference.bpm.rounded())) BPM · \(reference.beat_times.count) counts",
            playbackRate: 1.0,
            isTeacherMirrored: mirrorTeacher,
            hasTeacherVideo: false,
            currentBeatCount: 1,
            currentPhrase: 1,
            referencePose: pose,
            nextUnlocked: hasAvailableMoves
        )
    }

    // MARK: - Gestures & Coaching Commands

    func handle(_ command: CoachingCommand, fromCoordinator: Bool = false) {
        if phase == .analyzing {
            if !fromCoordinator {
                showToast("Analyzing take…")
            }
            return
        }
        switch command {
        case .startTake, .restartPreview:
            if !fromCoordinator {
                showToast("Start take")
            }
            startTake()

        case .togglePreviewPlayPause:
            if phase == .countIn || phase == .recording {
                abortTake(to: .paused)
                status = "Paused. Clap or raise both hands to resume."
                if !fromCoordinator {
                    showToast("Paused")
                }
            } else {
                if !fromCoordinator {
                    showToast("Start take")
                }
                startTake()
            }

        case .pauseTake:
            abortTake(to: .paused)
            status = "Paused. Clap or raise both hands to resume."
            if !fromCoordinator {
                showToast("Paused")
            }

        case .nextItem:
            abortTake(to: .idle)
            nextMove()
            let label = "Next move: \(selectedMove.isEmpty ? "none" : selectedMove)"
            if fromCoordinator {
                coordinator.showToast(label)
            } else {
                showToast(label)
            }

        case .returnToReview:
            abortTake(to: .idle)
            result = nil
            resultPose = [:]
            coordinator.clearTakeResults()
            status = selectedMove.isEmpty
                ? "Pick a reference move, then clap, raise both hands, or tap Start."
                : "Move: \(selectedMove). Clap, raise both hands, or tap Start."

        case .repeatCalibrationCue:
            if !fromCoordinator {
                calibration.repeatCurrentCue()
            }

        case .skipCalibration:
            if !fromCoordinator {
                calibration.skip()
            }
        }
    }

    /// Legacy 4-case `GestureCommand` entry point routed through `GestureRouter`'s v2 phase matrix.
    func handle(_ command: GestureCommand) {
        if phase == .analyzing {
            showToast("Analyzing take…")
            return
        }
        let now = CoachingStageCoordinator.currentHostTimeSeconds()
        if coordinator.router.isInResultsGraceWindow(at: now) {
            return
        }
        guard let routed = GestureRouter.route(
            legacyCommand: command,
            phase: phase.coachingPhase,
            host: .practice,
            passed: result?.passed ?? false,
            nextUnlocked: hasAvailableMoves
        ) else {
            return
        }
        handle(routed, fromCoordinator: false)
    }

    func handlePhonePauseResumeButton() {
        switch phase {
        case .countIn, .recording:
            abortTake(to: .paused)
            status = "Paused. Clap, raise both hands, or tap Resume."
        case .calibrating:
            abortTake(to: .paused)
            status = "Calibration paused. Tap Resume or Use Phone Screen."
        case .analyzing:
            break
        case .idle, .results, .paused:
            startTake()
        }
    }

    private func handleAirPlayDropped(in droppedPhase: CoachingPhase) {
        switch droppedPhase {
        case .countIn, .recording:
            abortTake(to: .paused)
            status = CalibrationVoice.airPlayDisconnectedMidTakeText
        case .calibrating, .clapSync:
            abortTake(to: .paused)
            calibration.unlockExposure()
            status = CalibrationVoice.airPlayDisconnectedMidCalibrationText
        case .analyzing:
            break
        case .idle, .results, .paused:
            status = CalibrationVoice.airPlayDisconnectedMidTakeText
        }
    }

    private func handleAirPlayReconnected() {
        status = CalibrationVoice.airPlayReconnectedText
    }

    private func handleRecalibrateStudioRequested() {
        calibrationSkipped = false
        if phase == .calibrating {
            abortTake(to: .idle)
            status = "Studio recalibration queued. Clap, raise both hands, or tap Start."
        }
    }

    private func nextMove() {
        guard let library else { return }
        let moves = library.references.keys.sorted()
        guard !moves.isEmpty else { return }
        let idx = moves.firstIndex(of: selectedMove).map { ($0 + 1) % moves.count } ?? 0
        selectedMove = moves[idx]
        status = "Move: \(selectedMove). Clap, raise both hands, or tap Start."
    }

    private func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled else { return }
            self.toast = nil
        }
    }

    // MARK: - Takes

    func startTake() {
        abortTake(to: .idle)
        guard let library, let reference = library.references[selectedMove] else {
            status = "Import a reference clip in the Calibrate tab first."
            return
        }
        guard !reference.beat_times.isEmpty else {
            status = "Reference \(selectedMove) has no beats."
            return
        }
        coordinator.clearTakeResults()
        syncSelectedMoveToStage()
        guard !calibrationSkipped else {
            runTake(
                reference: reference,
                library: library,
                profile: nil,
                profileV2: nil,
                cameraGravity: nil,
                skipped: true
            )
            return
        }
        phase = .calibrating
        status = "Calibrating: follow the voice, or double-clap / tap Skip."
        calibration.begin(camera: camera) { [weak self] outcome in
            guard let self, self.phase == .calibrating else { return }
            if outcome.skipped {
                self.calibrationSkipped = true
                self.runTake(
                    reference: reference,
                    library: library,
                    profile: nil,
                    profileV2: nil,
                    cameraGravity: outcome.cameraGravity,
                    skipped: true
                )
                return
            }
            self.status = outcome.resumed ? "Setup unchanged. Locked in!" : "Locked in!"
            // Let "Locked in!" finish before the count-in clicks.
            self.takeTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled, self.phase == .calibrating else { return }
                self.runTake(
                    reference: reference,
                    library: library,
                    profile: outcome.profile,
                    profileV2: outcome.profileV2,
                    cameraGravity: outcome.cameraGravity,
                    skipped: false
                )
            }
        }
    }

    /// Count-in, record and score one take. `profile` / `profileV2` are nil when calibration was skipped.
    private func runTake(
        reference: GrooveScoringEngine.PoseClip,
        library: GrooveLibrary,
        profile: CalibrationProfile?,
        profileV2: CalibrationProfileV2?,
        cameraGravity: [Double]?,
        skipped: Bool
    ) {
        takeTask?.cancel()
        takeTask = nil
        let period = 60.0 / reference.bpm
        let beats = reference.beat_times
        guard let firstBeat = beats.first, let lastBeat = beats.last else {
            phase = .idle
            return
        }
        // Timeline: playback start -> 4 count-in clicks -> take time zero (T0) -> reference beat grid.
        let countIn = Double(Self.countInBeats) * period
        let countInClicks = (0..<Self.countInBeats).map { firstBeat + Double($0) * period }
        let beatClicks = beats.map { countIn + $0 }
        let duration = countIn + lastBeat + period
        let clicks = countInClicks + beatClicks

        takeCounter += 1
        let takeURL = FileManager.default.temporaryDirectory.appendingPathComponent("practice_take_\(takeCounter).mov")
        camera.startRecording(to: takeURL)

        let playbackStart: Double
        do {
            playbackStart = try metronome.start(clickTimes: clicks, accented: Set(0..<Self.countInBeats), duration: duration)
        } catch {
            camera.cancelRecording()
            phase = .idle
            status = "Audio error: \(error.localizedDescription)"
            return
        }
        let timeZero = playbackStart + countIn
        let effectiveLatencyMs = coordinator.effectiveAudioLatencyMs(baseOutputLatencyMs: metronome.outputLatencyMs)
        let activeMode = camera.activeCameraMode
        // Camera-frame gravity aligned with `CanonicalSkeleton` axes (`+x` right, `+y` up, `+z` toward lens; §1.2).
        let gravity = cameraGravity
            ?? profile.map { activeMode.cameraFrameGravity(fromDeviceGravity: $0.gravity) }
            ?? currentCameraGravity(for: activeMode)
        let calibrationFrames = skipped ? nil : profile?.frames
        let scoringCalibrationV2 = coordinator.scoringCalibration(skipped: skipped, outcomeProfileV2: profileV2)
        let mirrored = mirrorTeacher
        let golden = library.goldenClips(for: reference.move_tag)
        let config = library.config

        phase = .countIn
        status = "Count-in…"
        takeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Show 4-3-2-1 on the count-in clicks, then switch to recording on the first real beat.
            for beat in 0..<Self.countInBeats {
                try? await Task.sleep(nanoseconds: Self.nanos(until: playbackStart + firstBeat + Double(beat) * period))
                if Task.isCancelled { return }
                self.countInBeatsLeft = Self.countInBeats - beat
            }
            try? await Task.sleep(nanoseconds: Self.nanos(until: timeZero + firstBeat))
            if Task.isCancelled { return }
            self.countInBeatsLeft = 0
            self.phase = .recording
            self.status = "Dance! \(beats.count) counts."
            self.coordinator.updateStage(
                countInBeatsLeft: 0,
                currentBeatCount: 1,
                currentPhrase: 1,
                referencePose: Self.displayPose(take: reference, at: firstBeat, mirrored: mirrored)
            )
            for (idx, beatTime) in beats.enumerated().dropFirst() {
                try? await Task.sleep(nanoseconds: Self.nanos(until: timeZero + beatTime))
                if Task.isCancelled { return }
                self.coordinator.updateStage(
                    currentBeatCount: (idx % 8) + 1,
                    currentPhrase: (idx / 8) + 1,
                    referencePose: Self.displayPose(take: reference, at: beatTime, mirrored: mirrored)
                )
            }
            try? await Task.sleep(nanoseconds: Self.nanos(until: playbackStart + duration))
            if Task.isCancelled { return }

            self.metronome.stop()
            self.phase = .analyzing
            self.status = "Analyzing take (MediaPipe body + hands)…"
            guard let output = await self.camera.finishRecording() else {
                self.phase = .idle
                self.status = "Recording failed. Try again."
                return
            }
            let take = await Self.buildTake(
                output: output,
                timeZero: timeZero,
                reference: reference,
                gravity: gravity,
                calibrationFrames: calibrationFrames,
                calibrationV2: scoringCalibrationV2,
                mirrored: mirrored,
                latencyMs: effectiveLatencyMs,
                takeNumber: self.takeCounter
            )
            if Task.isCancelled { return }
            guard let take, take.frames.count >= 10 else {
                let refusalMessage = "No dancer found in the take: step back so your whole body is in frame."
                self.coordinator.setScoreResult(nil, resultPose: [:], gradingRefusalReason: refusalMessage)
                self.phase = .idle
                self.status = refusalMessage
                return
            }
            let scored = await Task.detached(priority: .userInitiated) {
                GrooveScoringEngine.scoreAttempt(attempt: take, reference: reference, config: config, goldenClips: golden)
            }.value
            if Task.isCancelled { return }
            DebugLog.info("take_end practice")
            DebugLink.shared.sendEvent(kind: "take_end", fields: Self.takeSummary(scored, take: take))
            let pose = Self.displayPose(take: take, at: firstBeat, mirrored: mirrored)
            self.result = scored
            self.resultPose = pose
            self.coordinator.setScoreResult(scored, resultPose: pose, gradingRefusalReason: nil)
            self.phase = .results
            self.status = scored.passed
                ? "Pass! Clap or swipe right for the next move."
                : "Swipe left or raise hands to replay, or clap for another take."
        }
    }

    func abortTake(to newPhase: Phase) {
        takeTask?.cancel()
        takeTask = nil
        calibration.cancel()
        metronome.stop()
        if phase == .countIn || phase == .recording {
            camera.cancelRecording()
        }
        countInBeatsLeft = 0
        phase = newPhase
    }

    private func currentCameraGravity(for mode: CameraMode? = nil) -> [Double] {
        calibration.currentCameraGravity(for: mode ?? camera.activeCameraMode)
    }

    /// One Debug Link line per take end.
    static func takeSummary(_ r: GrooveScoringEngine.AttemptScoreResult,
                            take: GrooveScoringEngine.PoseClip) -> [String: Any] {
        [
            "clipId": r.clip_id,
            "passed": r.passed,
            "shapeScore": r.shape_score,
            "grooveScore": r.groove_score,
            "coverageRatio": r.coverage_ratio,
            "meanOffsetMs": r.mean_offset_ms,
            "goodOrBetterRatio": r.good_or_better_ratio,
            "retargeted": r.retargeted,
            "topIssue": r.top_issue,
            "frames": take.frames.count,
            "calibrationFrames": take.calibration_frames?.count ?? 0,
            "calibrationV2": take.calibration_v2 != nil,
            "audioLatencyMs": take.audio_latency_ms ?? 0.0,
            "gravity": take.gravity_vector ?? []
        ]
    }

    private static func nanos(until hostSeconds: Double) -> UInt64 {
        let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        return UInt64(max(0.0, hostSeconds - now) * 1_000_000_000)
    }

    /// Extracts the recorded take and re-times it onto the reference beat grid (t = 0 at the end of the count-in).
    private static func buildTake(
        output: TakeRecorder.Output,
        timeZero: Double,
        reference: GrooveScoringEngine.PoseClip,
        gravity: [Double],
        calibrationFrames: [GrooveScoringEngine.RawPoseFrame]?,
        calibrationV2: LearnerCalibrationV2?,
        mirrored: Bool,
        latencyMs: Double,
        takeNumber: Int
    ) async -> GrooveScoringEngine.PoseClip? {
        guard let frames = try? await VideoPoseExtractor.extractFrames(from: output.url, rebaseToFirstSample: true) else {
            return nil
        }
        let shift = output.firstFrameHostSeconds - timeZero
        let retimed = frames.compactMap { frame -> GrooveScoringEngine.RawPoseFrame? in
            let t = frame.t + shift
            guard t >= 0.0 else { return nil }
            return GrooveScoringEngine.RawPoseFrame(t: t, joints: frame.joints, confidences: frame.confidences, hands: frame.hands)
        }
        try? FileManager.default.removeItem(at: output.url)
        return GrooveScoringEngine.PoseClip(
            clip_id: String(format: "practice_%03d_%@", takeNumber, reference.move_tag),
            move_tag: reference.move_tag,
            bpm: reference.bpm,
            beat_times: reference.beat_times,
            gravity_vector: gravity,
            mirrored: mirrored,
            audio_latency_ms: latencyMs,
            speed_pct: 100,
            expected: nil,
            frames: retimed,
            calibration_frames: calibrationFrames,
            calibration_v2: calibrationV2
        )
    }

    /// Learner or reference pose at time `t`, as a front-view stick figure (normalised, y down).
    public static func displayPose(take: GrooveScoringEngine.PoseClip, at t: Double, mirrored: Bool) -> [String: CGPoint] {
        var pose = GrooveScoringEngine.bodyNormalizedPose(
            frames: take.frames,
            at: t,
            gravityVector: GrooveScoringEngine.Vec3(array: take.gravity_vector ?? [0.0, -1.0, 0.0]),
            mirror: mirrored
        )
        pose["root"] = [0.0, 0.0, 0.0]
        let xs = pose.values.map { $0[0] }
        let ys = pose.values.map { $0[1] }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return [:] }
        let span = max(maxX - minX, maxY - minY, 1e-6)
        var out: [String: CGPoint] = [:]
        for (name, p) in pose {
            let x = 0.5 + (p[0] - 0.5 * (minX + maxX)) / span * 0.9
            let y = 0.5 - (p[1] - 0.5 * (minY + maxY)) / span * 0.9
            out[name] = CGPoint(x: x, y: y)
        }
        return out
    }
}

struct PracticeView: View {
    @EnvironmentObject private var library: GrooveLibrary
    @StateObject private var model = PracticeViewModel()

    var body: some View {
        NavigationStack {
            PracticeStageContent(
                model: model,
                coordinator: model.coordinator,
                camera: model.camera
            )
            .navigationTitle("Practice")
            .onAppear {
                model.library = library
                model.onAppear(library: library)
            }
            .onDisappear { model.onDisappear() }
        }
    }
}

@MainActor
private struct PracticeStageContent: View {
    @EnvironmentObject private var library: GrooveLibrary
    @ObservedObject var model: PracticeViewModel
    @ObservedObject var coordinator: CoachingStageCoordinator
    @ObservedObject var camera: PracticeCamera

    private var activeToast: String? {
        model.toast ?? coordinator.toastText
    }

    private var isMidTakeOrAnalyzing: Bool {
        model.phase == .countIn || model.phase == .recording || model.phase == .analyzing
    }

    var body: some View {
        Group {
            if coordinator.shouldShowPhoneControllerStatus {
                // Pure `#000000` OLED controller screen with zero camera preview layers while TV stage is active (§1.2, §4.1).
                coordinator.makePhoneControllerStatusView(
                    title: model.stageTitle,
                    statusText: model.status,
                    onPauseResume: {
                        model.handlePhonePauseResumeButton()
                    },
                    onSkipCalibration: {
                        model.calibration.skip()
                    }
                )
            } else {
                phonePracticeBody
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if coordinator.shouldShowPhoneControllerStatus {
                    if !library.references.isEmpty {
                        Picker("Move", selection: $model.selectedMove) {
                            ForEach(library.references.keys.sorted(), id: \.self) { move in
                                Text(move).tag(move)
                            }
                        }
                        .pickerStyle(.menu)
                        .disabled(isMidTakeOrAnalyzing)
                    }
                } else {
                    if coordinator.isExternalDisplayConnected && coordinator.isPhoneScreenForced {
                        Button {
                            coordinator.resumeTVStage()
                        } label: {
                            Label("TV Stage", systemImage: "tv.fill")
                        }
                        .disabled(isMidTakeOrAnalyzing)
                    }
                    Button {
                        coordinator.toggleCameraMode()
                    } label: {
                        Label(
                            coordinator.cameraMode.isRear ? "Front Cam" : "Rear Cam",
                            systemImage: "arrow.triangle.2.circlepath.camera"
                        )
                    }
                    .disabled(isMidTakeOrAnalyzing)
                }
            }
        }
    }

    private var phonePracticeBody: some View {
        VStack(spacing: 12) {
            ZStack(alignment: .top) {
                // Phone preview is mirrored in both front and manual rear camera modes so `SkeletonOverlay` and
                // `CalibrationOverlayView` match `PracticeCamera.mirrorForDisplay = true` (§1.2, §10 #13).
                CameraPreview(session: camera.session, mirrored: true)
                    .id(coordinator.cameraMode)
                LiveOverlay(camera: camera, severities: JointSeverityMap.from(model.result?.joint_feedback))
                if model.phase == .calibrating {
                    CalibrationOverlayView(
                        controller: model.calibration,
                        imageAspect: camera.skeleton.imageAspect,
                        compact: true
                    )
                }
                VStack(spacing: 8) {
                    if let toast = activeToast {
                        GestureToast(text: toast)
                    }
                    if model.phase != .calibrating {
                        GestureHoldRingView(
                            progress: camera.gestureHoldProgress,
                            phase: model.phase.coachingPhase,
                            tvScale: false
                        )
                    }
                }
                .padding(.top, 12)

                if model.countInBeatsLeft > 0 {
                    Text("\(model.countInBeatsLeft)")
                        .font(.system(size: 96, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(radius: 8)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 380)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .animation(.easeInOut(duration: 0.2), value: activeToast)

            controls

            if model.phase == .results, let result = model.result {
                ScrollView {
                    TakeResultView(result: result, pose: model.resultPose)
                }
            } else {
                Text(model.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }
        }
        .padding()
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("Move", selection: $model.selectedMove) {
                    if library.references.isEmpty {
                        Text("No references").tag("")
                    }
                    ForEach(library.references.keys.sorted(), id: \.self) { move in
                        Text(move).tag(move)
                    }
                }
                .pickerStyle(.menu)
                Toggle("Mirror teacher", isOn: $model.mirrorTeacher)
                    .toggleStyle(.switch)
                    .font(.caption)
            }
            HStack {
                Button {
                    if model.phase == .calibrating {
                        model.abortTake(to: .idle)
                        model.status = "Calibration cancelled. Clap, raise both hands, or tap Start."
                    } else if model.phase == .countIn || model.phase == .recording {
                        model.abortTake(to: .paused)
                        model.status = "Stopped. Clap, raise both hands, or tap Start."
                    } else {
                        model.startTake()
                    }
                } label: {
                    Label(primaryTitle, systemImage: primaryIcon)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.phase == .analyzing || library.references.isEmpty)
                if model.phase == .analyzing {
                    ProgressView()
                }
            }
            Text("Hands-free: both hands up start/pause · clap start/continue · swipe ← replay · swipe → next move")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var primaryTitle: String {
        switch model.phase {
        case .calibrating: return "Cancel"
        case .countIn, .recording: return "Stop"
        default: return "Start take"
        }
    }

    private var primaryIcon: String {
        switch model.phase {
        case .calibrating: return "xmark"
        case .countIn, .recording: return "stop.fill"
        default: return "record.circle"
        }
    }
}

/// Live skeleton (coloured by the last take's verdicts) and live hand-shape labels over the camera.
struct LiveOverlay: View {
    @ObservedObject var camera: PracticeCamera
    let severities: [String: String]

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            SkeletonOverlay(joints: camera.skeleton.joints, severities: severities, imageAspect: camera.skeleton.imageAspect)
            if !camera.handShapes.isEmpty {
                Text(handLabel)
                    .font(.caption.bold())
                    .padding(6)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .padding(8)
            }
            if let error = camera.cameraError {
                Text(error).font(.caption).foregroundStyle(.red).padding(8)
            }
        }
    }

    private var handLabel: String {
        ["left", "right"].compactMap { side in
            camera.handShapes[side].map { "\(side == "left" ? "L" : "R"): \($0)" }
        }.joined(separator: "  ·  ")
    }
}

/// `AVCaptureVideoPreviewLayer` host (aspect-fit so the overlay mapping matches; horizontally mirrored by default
/// in both front and rear camera modes so phone overlays match `PracticeCamera.mirrorForDisplay = true`, §1.2).
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var mirrored: Bool = true

    init(session: AVCaptureSession, mirrored: Bool = true) {
        self.session = session
        self.mirrored = mirrored
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        var desiredMirrored: Bool = true
        private var connectionRetryTask: Task<Void, Never>?

        override func layoutSubviews() {
            super.layoutSubviews()
            applyImmediateConnectionSettings()
        }

        override func willMove(toWindow newWindow: UIWindow?) {
            super.willMove(toWindow: newWindow)
            if newWindow == nil {
                connectionRetryTask?.cancel()
                connectionRetryTask = nil
            }
        }

        @discardableResult
        func applyImmediateConnectionSettings() -> Bool {
            guard let connection = previewLayer.connection else { return false }
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            if connection.isVideoMirroringSupported {
                // `automaticallyAdjustsVideoMirroring` must be false before assigning `isVideoMirrored`.
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = desiredMirrored
            }
            return true
        }

        func syncConnectionSettings(retriesLeft: Int = 8) {
            connectionRetryTask?.cancel()
            connectionRetryTask = nil

            if applyImmediateConnectionSettings() {
                // Re-apply once more shortly after session reconfiguration in case `videoQueue` swaps inputs asynchronously.
                connectionRetryTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    guard let self, !Task.isCancelled else { return }
                    self.applyImmediateConnectionSettings()
                }
            } else if retriesLeft > 0, previewLayer.session != nil {
                connectionRetryTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    guard let self, !Task.isCancelled else { return }
                    self.syncConnectionSettings(retriesLeft: retriesLeft - 1)
                }
            }
        }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.desiredMirrored = mirrored
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        view.syncConnectionSettings()
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.desiredMirrored = mirrored
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
        uiView.previewLayer.videoGravity = .resizeAspect
        uiView.syncConnectionSettings()
    }
}
