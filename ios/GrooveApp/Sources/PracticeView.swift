import AVFoundation
import CoreMotion
import GrooveCore
import SwiftUI
import UIKit

/// Live practice loop: count-in clicks -> record a take -> score it against the selected reference move.
/// Hands-free: swipe left = replay the drill, swipe right = next move, clap = pause / resume,
/// both hands above the head = restart.
@MainActor
final class PracticeViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle, countIn, recording, analyzing, results, paused
    }

    @Published var phase: Phase = .idle
    @Published var selectedMove: String = ""
    @Published var mirrorTeacher = true
    @Published var toast: String?
    @Published var status = "Pick a reference move, then clap or tap Start."
    @Published var result: GrooveScoringEngine.AttemptScoreResult?
    @Published var resultPose: [String: CGPoint] = [:]
    @Published var countInBeatsLeft = 0

    let camera = PracticeCamera()
    weak var library: GrooveLibrary?
    private let metronome = Metronome()
    private let motion = CMMotionManager()
    private var takeTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var takeCounter = 0

    static let countInBeats = 4

    init() {
        camera.onGesture = { [weak self] command in
            Task { @MainActor in self?.handle(command) }
        }
    }

    func onAppear(library: GrooveLibrary) {
        UIApplication.shared.isIdleTimerDisabled = true
        if selectedMove.isEmpty || library.references[selectedMove] == nil {
            selectedMove = library.references.keys.sorted().first ?? ""
        }
        if motion.isDeviceMotionAvailable && !motion.isDeviceMotionActive {
            motion.deviceMotionUpdateInterval = 1.0 / 30.0
            motion.startDeviceMotionUpdates()
        }
        Task {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if granted {
                camera.start()
            } else {
                status = "Camera access is off: enable it in Settings > Groove Coach."
            }
        }
    }

    func onDisappear() {
        UIApplication.shared.isIdleTimerDisabled = false
        abortTake(to: .idle)
        camera.stop()
        motion.stopDeviceMotionUpdates()
    }

    // MARK: - Gestures

    func handle(_ command: GestureCommand) {
        guard phase != .analyzing else {
            showToast("Analyzing take…")
            return
        }
        switch command {
        case .swipeRight:
            abortTake(to: .idle)
            nextMove()
            showToast("Next move: \(selectedMove.isEmpty ? "none" : selectedMove)")
        case .swipeLeft:
            showToast("Replay drill")
            startTake()
        case .togglePause:
            if phase == .countIn || phase == .recording {
                abortTake(to: .paused)
                status = "Paused. Clap to resume."
                showToast("Paused")
            } else {
                showToast("Resumed")
                startTake()
            }
        case .restartDrill:
            showToast("Restart")
            startTake()
        }
    }

    private func nextMove() {
        guard let library else { return }
        let moves = library.references.keys.sorted()
        guard !moves.isEmpty else { return }
        let idx = moves.firstIndex(of: selectedMove).map { ($0 + 1) % moves.count } ?? 0
        selectedMove = moves[idx]
        status = "Move: \(selectedMove). Clap or tap Start."
    }

    private func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled { toast = nil }
        }
    }

    // MARK: - Takes

    func startTake() {
        abortTake(to: .idle)
        guard let library, let reference = library.references[selectedMove] else {
            status = "Import a reference clip in the Calibrate tab first."
            return
        }
        let period = 60.0 / reference.bpm
        let beats = reference.beat_times
        guard let firstBeat = beats.first, let lastBeat = beats.last else {
            status = "Reference \(selectedMove) has no beats."
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
            status = "Audio error: \(error.localizedDescription)"
            return
        }
        let timeZero = playbackStart + countIn
        let latencyMs = metronome.outputLatencyMs
        let gravity = currentGravity()
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
            try? await Task.sleep(nanoseconds: Self.nanos(until: playbackStart + duration))
            if Task.isCancelled { return }

            self.metronome.stop()
            self.phase = .analyzing
            self.status = "Analyzing take (Vision 3D + feet + hands)…"
            guard let output = await self.camera.finishRecording() else {
                self.phase = .idle
                self.status = "Recording failed. Try again."
                return
            }
            let take = await Self.buildTake(
                output: output, timeZero: timeZero, reference: reference, gravity: gravity,
                mirrored: mirrored, latencyMs: latencyMs, takeNumber: self.takeCounter
            )
            if Task.isCancelled { return }
            guard let take, take.frames.count >= 10 else {
                self.phase = .idle
                self.status = "No dancer found in the take: step back so your whole body is in frame."
                return
            }
            let scored = await Task.detached(priority: .userInitiated) {
                GrooveScoringEngine.scoreAttempt(attempt: take, reference: reference, config: config, goldenClips: golden)
            }.value
            if Task.isCancelled { return }
            self.result = scored
            self.resultPose = Self.displayPose(take: take, at: firstBeat, mirrored: mirrored)
            self.phase = .results
            self.status = scored.passed ? "Pass! Swipe right for the next move." : "Swipe left to replay, or clap for another take."
        }
    }

    func abortTake(to newPhase: Phase) {
        takeTask?.cancel()
        takeTask = nil
        metronome.stop()
        if phase == .countIn || phase == .recording {
            camera.cancelRecording()
        }
        countInBeatsLeft = 0
        phase = newPhase
    }

    private func currentGravity() -> [Double] {
        guard let g = motion.deviceMotion?.gravity else { return [0.0, -1.0, 0.0] }
        return [g.x, g.y, g.z]
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
            frames: retimed
        )
    }

    /// Learner pose at the first beat, as a front-view stick figure (normalised, y down).
    private static func displayPose(take: GrooveScoringEngine.PoseClip, at t: Double, mirrored: Bool) -> [String: CGPoint] {
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
            VStack(spacing: 12) {
                ZStack(alignment: .top) {
                    CameraPreview(session: model.camera.session)
                    LiveOverlay(camera: model.camera, severities: JointSeverityMap.from(model.result?.joint_feedback))
                    if let toast = model.toast {
                        GestureToast(text: toast).padding(.top, 12)
                    }
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
                .animation(.easeInOut(duration: 0.2), value: model.toast)

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
            .navigationTitle("Practice")
            .onAppear {
                model.library = library
                model.onAppear(library: library)
            }
            .onDisappear { model.onDisappear() }
        }
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
                    if model.phase == .countIn || model.phase == .recording {
                        model.abortTake(to: .paused)
                        model.status = "Stopped. Clap or tap Start."
                    } else {
                        model.startTake()
                    }
                } label: {
                    Label(model.phase == .countIn || model.phase == .recording ? "Stop" : "Start take",
                          systemImage: model.phase == .countIn || model.phase == .recording ? "stop.fill" : "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.phase == .analyzing || library.references.isEmpty)
                if model.phase == .analyzing {
                    ProgressView()
                }
            }
            Text("Hands-free: swipe ← replay · swipe → next move · clap pause/resume · both hands up restart")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// Live skeleton (coloured by the last take's verdicts) and live hand-shape labels over the camera.
private struct LiveOverlay: View {
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

/// `AVCaptureVideoPreviewLayer` host (aspect-fit so the overlay mapping matches; selfie preview is mirrored).
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        if let connection = uiView.previewLayer.connection, connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
    }
}
