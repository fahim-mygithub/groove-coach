import AVFoundation
import Combine
import CoreMedia
import GrooveCore
import SwiftUI
import UIKit

/// Player view for learning and practicing a lesson segment end to end (spec §2.4, §8 Q6):
/// - Teacher AVPlayer with pitch-preserving algorithm (`audioTimePitchAlgorithm = .timeDomain`),
/// - Starts takes with sample-accurate host-time synchronization using Metronome and `player.setRate(atHostTime:)`,
/// - Front camera recording with live skeleton overlay during the take,
/// - Post-take pose extraction via injected closure: `extractPoses: (URL) async throws -> [RawPoseFrame]`,
/// - Reference slicing & stretching with GrooveCore `LessonPackage.sliceReference` and `stretch`,
/// - Scoring via `GrooveScoringEngine.scoreAttempt` applying lesson & segment `config_overrides` and windows,
/// - Adaptive speed progression via GrooveCore `LessonPackage.nextRate(policy, history)` with per-segment persistence,
/// - Mirror semantics per spec §2.2 (default flipped teacher video; "as filmed" toggle -> scoring mirrored = true),
/// - Grading guard refusing to score when pose model SHA256 or engine major differ,
/// - Exporting attempt bundles via iOS share sheet (`AttemptExport`).
public struct LessonPlayerView: View {
    @StateObject private var viewModel: LessonPlayerViewModel
    @Environment(\.dismiss) private var dismiss

    public init(
        manifest: LessonPackage.Manifest,
        segment: LessonPackage.Segment,
        videoURL: URL?,
        extractPoses: (@Sendable (URL) async throws -> [GrooveScoringEngine.RawPoseFrame])? = nil
    ) {
        _viewModel = StateObject(
            wrappedValue: LessonPlayerViewModel(
                manifest: manifest,
                segment: segment,
                videoURL: videoURL,
                extractPoses: extractPoses
            )
        )
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // Top navigation bar
                topNavigationBar

                // Viewport area
                ZStack {
                    if viewModel.isTakingTake {
                        // Take Mode: Front camera active with live overlay and PIP of teacher video
                        takeViewportView
                    } else {
                        // Review Mode: Full teacher video with beat indicators
                        reviewViewportView
                    }

                    // Count-in HUD
                    if viewModel.isCountIn {
                        countInOverlay
                    }

                    // Beat counter overlay
                    VStack {
                        Spacer()
                        beatCounterOverlay
                            .padding(.bottom, 12)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Bottom control panel
                bottomControlsPanel
            }
        }
        .sheet(isPresented: $viewModel.showResultsSheet) {
            resultsSheetView
        }
        .sheet(isPresented: $viewModel.showShareSheet) {
            if let shareURL = viewModel.shareURL {
                ShareSheet(activityItems: [shareURL])
            }
        }
        .onAppear {
            viewModel.onAppear()
        }
        .onDisappear {
            viewModel.onDisappear()
        }
    }

    // MARK: - Viewport Subviews

    private var reviewViewportView: some View {
        ZStack {
            if viewModel.hasVideo {
                PlayerLayerView(player: viewModel.player, isMirrored: viewModel.isMirrored)
                    .clipped()
            } else {
                videoPlaceholderView
            }
        }
    }

    private var takeViewportView: some View {
        ZStack(alignment: .topTrailing) {
            // Learner front camera
            CameraPreview(session: viewModel.camera.session)
                .clipped()

            LiveOverlay(
                camera: viewModel.camera,
                severities: JointSeverityMap.from(viewModel.latestScoreResult?.joint_feedback)
            )

            // Picture-in-picture of teacher video
            if viewModel.hasVideo {
                PlayerLayerView(player: viewModel.player, isMirrored: viewModel.isMirrored)
                    .frame(width: 120, height: 190)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.6), lineWidth: 1.5)
                    )
                    .shadow(radius: 6)
                    .padding(12)
            }

            // Recording badge
            VStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 10, height: 10)
                    Text("REC")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.65), in: Capsule())
                .padding(12)
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Top & Bottom Bars

    private var topNavigationBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.ultraThinMaterial, in: Circle())
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.segment.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("Segment \(viewModel.segment.id) • \(String(format: "%.1f–%.1fs", viewModel.segment.startS, viewModel.segment.endS))")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
            }

            Spacer()

            // "As Filmed" vs "Mirrored" flip toggle (spec §2.2)
            Button {
                viewModel.toggleMirror()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: viewModel.isMirrored ? "arrow.left.and.right.righttriangle.left.righttriangle.right" : "camera.viewfinder")
                    Text(viewModel.isMirrored ? "Mirrored" : "As Filmed")
                        .font(.caption.bold())
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(viewModel.isMirrored ? Color.indigo.opacity(0.7) : Color.white.opacity(0.2), in: Capsule())
                .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.6))
    }

    private var videoPlaceholderView: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.slash")
                .font(.system(size: 48))
                .foregroundStyle(.white.opacity(0.5))
            Text("Video Not Downloaded")
                .font(.headline)
                .foregroundStyle(.white)
            Text("Download this lesson from Courses or import from Files in Dev Mode.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    private var countInOverlay: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 8) {
                Text("COUNT-IN")
                    .font(.caption.bold())
                    .tracking(2)
                    .foregroundStyle(.yellow)
                Text("\(viewModel.countInBeatsLeft)")
                    .font(.system(size: 96, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .yellow.opacity(0.6), radius: 16)
            }
            .transition(.scale.combined(with: .opacity))
        }
    }

    private var beatCounterOverlay: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("PHRASE \(viewModel.currentPhrase)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
                Text("COUNT \(viewModel.currentBeatCount)")
                    .font(.system(size: 14, weight: .black, design: .monospaced))
                    .foregroundStyle(.yellow)
            }
            .padding(.trailing, 4)

            // 1..8 Beat indicator track
            HStack(spacing: 5) {
                ForEach(1...8, id: \.self) { count in
                    ZStack {
                        Circle()
                            .fill(viewModel.currentBeatCount == count ? Color.yellow : Color.white.opacity(0.2))
                            .frame(width: 26, height: 26)
                        Text("\(count)")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(viewModel.currentBeatCount == count ? Color.black : Color.white)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(radius: 6)
    }

    private var bottomControlsPanel: some View {
        VStack(spacing: 12) {
            // Adaptive rate status & next segment unlock badge
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Adaptive Rate:")
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                        Text(String(format: "%.2fx", viewModel.playbackRate))
                            .font(.subheadline.monospacedDigit().bold())
                            .foregroundStyle(.green)
                    }
                    Text(viewModel.adaptiveStatusText)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                }

                Spacer()

                if viewModel.nextSegmentUnlocked {
                    Label("Next Unlocked", systemImage: "lock.open.fill")
                        .font(.caption2.bold())
                        .foregroundStyle(.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.2), in: Capsule())
                } else {
                    Label("Next Locked", systemImage: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.1), in: Capsule())
                }
            }
            .padding(.horizontal, 16)

            if !viewModel.statusMessage.isEmpty {
                Text(viewModel.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.yellow)
                    .padding(.horizontal, 16)
            }

            // Transport controls
            HStack(spacing: 20) {
                // Loop toggle
                Button {
                    viewModel.isLooping.toggle()
                } label: {
                    Image(systemName: viewModel.isLooping ? "repeat.1" : "repeat")
                        .font(.title3)
                        .foregroundStyle(viewModel.isLooping ? .yellow : .white.opacity(0.5))
                }

                // Restart from beginning with count-in
                Button {
                    viewModel.restartWithCountIn()
                } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                }

                // Play / Pause (review mode)
                Button {
                    viewModel.togglePlayPause()
                } label: {
                    Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.white)
                }

                // Practice / Start Take Button
                Button {
                    if viewModel.isTakingTake {
                        viewModel.abortTake()
                    } else {
                        viewModel.startTake()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: viewModel.isTakingTake ? "stop.fill" : "record.circle.fill")
                            .foregroundStyle(viewModel.isTakingTake ? .red : .yellow)
                        Text(viewModel.isTakingTake ? "Stop Take" : "Start Take")
                            .font(.subheadline.bold())
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(viewModel.isTakingTake ? Color.red.opacity(0.25) : Color.yellow.opacity(0.25), in: Capsule())
                    .foregroundStyle(.white)
                }
                .disabled(viewModel.phase == .analyzing)

                // Manual speed selector
                Menu {
                    Button("0.60x (Minimum)") { viewModel.setRateManually(0.60) }
                    Button("0.70x (Start Rate)") { viewModel.setRateManually(0.70) }
                    Button("0.80x (Unlock Bar)") { viewModel.setRateManually(0.80) }
                    Button("0.90x") { viewModel.setRateManually(0.90) }
                    Button("1.00x (Full Tempo)") { viewModel.setRateManually(1.00) }
                } label: {
                    Image(systemName: "speedometer")
                        .font(.title3)
                        .foregroundStyle(.white)
                }

                // Testing & simulation menu
                Menu {
                    Button("Simulate Pass Take (Clean)") { viewModel.simulateTake(passed: true) }
                    Button("Simulate Fail Take") { viewModel.simulateTake(passed: false) }
                    Button("Reset Take History") { viewModel.resetHistory() }
                    if viewModel.latestScoreResult != nil {
                        Button("View Last Results") { viewModel.showResultsSheet = true }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(.cyan)
                }
            }
            .padding(.vertical, 4)
        }
        .padding(.top, 8)
        .padding(.bottom, 20)
        .background(Color.black.opacity(0.85))
    }

    // MARK: - Results Sheet

    private var resultsSheetView: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let reason = viewModel.gradingRefusalReason {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text("Grading Refused")
                                    .font(.headline)
                            }
                            Text(reason)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                    } else if let result = viewModel.latestScoreResult {
                        TakeResultView(result: result, pose: viewModel.latestResultPose) {
                            viewModel.exportAttemptBundle()
                        }
                    }

                    HStack(spacing: 12) {
                        Button {
                            viewModel.showResultsSheet = false
                            viewModel.startTake()
                        } label: {
                            Label("Take Again", systemImage: "arrow.clockwise")
                                .font(.subheadline.bold())
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            viewModel.showResultsSheet = false
                        } label: {
                            Text("Done")
                                .font(.subheadline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.top, 8)
                }
                .padding()
            }
            .navigationTitle("Take Results")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if viewModel.latestScoreResult != nil && viewModel.gradingRefusalReason == nil {
                        Button {
                            viewModel.exportAttemptBundle()
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
    }
}

// MARK: - View Model

@MainActor
public final class LessonPlayerViewModel: ObservableObject {
    public enum Phase: Equatable {
        case idle, countIn, recording, analyzing, results
    }

    @Published public var phase: Phase = .idle
    @Published public var isPlaying: Bool = false
    @Published public var isCountIn: Bool = false
    @Published public var isMirrored: Bool = true
    @Published public var isLooping: Bool = true
    @Published public var countInBeatsLeft: Int = 4
    @Published public var currentBeatCount: Int = 1
    @Published public var currentPhrase: Int = 1
    @Published public var playbackRate: Double = 0.70
    @Published public var nextSegmentUnlocked: Bool = false
    @Published public var takeHistory: [LessonPackage.Take] = []
    @Published public var statusMessage: String = ""
    @Published public var latestScoreResult: GrooveScoringEngine.AttemptScoreResult?
    @Published public var latestTakeClip: GrooveScoringEngine.PoseClip?
    @Published public var latestRefClip: GrooveScoringEngine.PoseClip?
    @Published public var latestResultPose: [String: CGPoint] = [:]
    @Published public var gradingRefusalReason: String?
    @Published public var showResultsSheet: Bool = false
    @Published public var showShareSheet: Bool = false
    @Published public var shareURL: URL?

    public let manifest: LessonPackage.Manifest
    public let segment: LessonPackage.Segment
    public let videoURL: URL?
    public let player = AVPlayer()
    public let camera = PracticeCamera()
    public let extractPoses: @Sendable (URL) async throws -> [GrooveScoringEngine.RawPoseFrame]

    private let metronome = Metronome()
    private var timeObserverToken: Any?
    private var countInTask: Task<Void, Never>?
    private var takeExecutionTask: Task<Void, Never>?
    private var segmentBeats: [LessonPackage.Beat] = []
    private var takeCounter = 0

    public var hasVideo: Bool {
        videoURL != nil && FileManager.default.fileExists(atPath: videoURL!.path)
    }

    public var isTakingTake: Bool {
        phase == .countIn || phase == .recording
    }

    public var adaptiveStatusText: String {
        let policy = segment.adaptiveSpeed ?? manifest.practice.adaptiveSpeed
        return "Ladder: [\(String(format: "%.1f", policy.minRate))x - \(String(format: "%.1f", policy.maxRate))x] • Takes: \(takeHistory.count)"
    }

    public static let defaultExtractPoses: @Sendable (URL) async throws -> [GrooveScoringEngine.RawPoseFrame] = { url in
        try await VideoPoseExtractor.extractFrames(from: url, rebaseToFirstSample: false)
    }

    public init(
        manifest: LessonPackage.Manifest,
        segment: LessonPackage.Segment,
        videoURL: URL?,
        extractPoses: (@Sendable (URL) async throws -> [GrooveScoringEngine.RawPoseFrame])? = nil
    ) {
        self.manifest = manifest
        self.segment = segment
        self.videoURL = videoURL
        self.extractPoses = extractPoses ?? Self.defaultExtractPoses

        // Default display flip per manifest (spec §2.2)
        self.isMirrored = manifest.video.defaultDisplayFlip

        // Initial rate and history from persistent storage
        let policy = segment.adaptiveSpeed ?? manifest.practice.adaptiveSpeed
        let savedTakes = LessonStore.shared.loadTakes(
            lessonID: manifest.lessonID,
            version: manifest.packageVersion,
            segmentID: segment.id
        )
        self.takeHistory = savedTakes
        if let result = try? LessonPackage.nextRate(policy: policy, history: savedTakes) {
            self.playbackRate = result.rate
            self.nextSegmentUnlocked = result.unlocked
        } else {
            self.playbackRate = policy.startRate
            self.nextSegmentUnlocked = false
        }

        // Filter beats belonging to this segment
        self.segmentBeats = manifest.beatGrid.beats.filter {
            $0.t >= (segment.startS - 0.05) && $0.t <= (segment.endS + 0.05)
        }

        setupPlayer()
    }

    deinit {
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
        }
    }

    public func onAppear() {
        UIApplication.shared.isIdleTimerDisabled = true
        restartWithCountIn()
    }

    public func onDisappear() {
        UIApplication.shared.isIdleTimerDisabled = false
        stopPlayback()
        camera.stop()
    }

    public func toggleMirror() {
        isMirrored.toggle()
    }

    public func togglePlayPause() {
        if isPlaying {
            pausePlayback()
        } else {
            restartWithCountIn()
        }
    }

    // MARK: - Review Playback Flow

    public func restartWithCountIn() {
        guard hasVideo else { return }
        stopPlayback()

        let countInBeats = max(1, manifest.practice.countInBeats)
        let bpm = manifest.beatGrid.bpm
        let effectiveBPM = bpm * playbackRate
        let beatPeriod = 60.0 / effectiveBPM
        let countInDuration = Double(countInBeats) * beatPeriod

        let clickTimes = (0..<countInBeats).map { Double($0) * beatPeriod }
        let accented: Set<Int> = [0]

        player.seek(
            to: CMTime(seconds: segment.startS, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )

        let startInfo: Metronome.ScheduledStart
        do {
            startInfo = try metronome.startScheduled(
                clickTimes: clickTimes,
                accented: accented,
                duration: countInDuration + 0.1
            )
        } catch {
            player.play()
            player.rate = Float(playbackRate)
            isPlaying = true
            return
        }

        let videoMachTime = startInfo.machTime + AVAudioTime.hostTime(forSeconds: countInDuration)
        let hostClockTime = CMClockMakeHostTimeFromSystemUnits(videoMachTime)

        player.setRate(
            Float(playbackRate),
            time: CMTime(seconds: segment.startS, preferredTimescale: 600),
            atHostTime: hostClockTime
        )

        isCountIn = true
        countInBeatsLeft = countInBeats
        isPlaying = true

        countInTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for beat in 0..<countInBeats {
                self.countInBeatsLeft = countInBeats - beat
                try? await Task.sleep(nanoseconds: UInt64(beatPeriod * 1_000_000_000))
                if Task.isCancelled { return }
            }
            self.isCountIn = false
        }
    }

    public func pausePlayback() {
        metronome.stop()
        countInTask?.cancel()
        isCountIn = false
        player.pause()
        isPlaying = false
    }

    public func stopPlayback() {
        pausePlayback()
    }

    // MARK: - Take Flow (Spec §2.4)

    public func startTake() {
        stopPlayback()
        takeExecutionTask?.cancel()
        phase = .countIn
        statusMessage = "Starting take..."

        // Check model compatibility guard (spec §2.2)
        let (canGrade, refusalReason) = AttemptExport.canGrade(manifest: manifest)
        self.gradingRefusalReason = refusalReason

        let countInBeats = max(1, manifest.practice.countInBeats)
        let bpm = manifest.beatGrid.bpm
        let effectiveBPM = bpm * playbackRate
        let beatPeriod = 60.0 / effectiveBPM
        let countInDuration = Double(countInBeats) * beatPeriod
        let segmentMediaDuration = max(0.1, segment.endS - segment.startS)
        let segmentWallDuration = segmentMediaDuration / playbackRate

        let clickTimes = (0..<countInBeats).map { Double($0) * beatPeriod }
        let accented: Set<Int> = [0]

        takeCounter += 1
        let takeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lesson_take_\(takeCounter).mov")

        camera.start()
        camera.startRecording(to: takeURL)

        player.seek(
            to: CMTime(seconds: segment.startS, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )

        let startInfo: Metronome.ScheduledStart
        do {
            startInfo = try metronome.startScheduled(
                clickTimes: clickTimes,
                accented: accented,
                duration: countInDuration + segmentWallDuration + 0.5
            )
        } catch {
            camera.cancelRecording()
            camera.stop()
            phase = .idle
            statusMessage = "Audio error: \(error.localizedDescription)"
            return
        }

        let videoMachTime = startInfo.machTime + AVAudioTime.hostTime(forSeconds: countInDuration)
        let hostClockTime = CMClockMakeHostTimeFromSystemUnits(videoMachTime)
        let videoStartHostSeconds = startInfo.hostSeconds + countInDuration

        player.setRate(
            Float(playbackRate),
            time: CMTime(seconds: segment.startS, preferredTimescale: 600),
            atHostTime: hostClockTime
        )

        isCountIn = true
        countInBeatsLeft = countInBeats
        isPlaying = true

        takeExecutionTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // 1. Count-in countdown
            for beat in 0..<countInBeats {
                self.countInBeatsLeft = countInBeats - beat
                try? await Task.sleep(nanoseconds: UInt64(beatPeriod * 1_000_000_000))
                if Task.isCancelled { return }
            }
            self.isCountIn = false
            self.phase = .recording
            self.statusMessage = "Dance! Recording take..."

            // 2. Wait for segment duration
            try? await Task.sleep(nanoseconds: UInt64(segmentWallDuration * 1_000_000_000))
            if Task.isCancelled { return }

            // 3. Take completed: finish recording and stop AVPlayer
            self.metronome.stop()
            self.player.pause()
            self.isPlaying = false
            self.phase = .analyzing
            self.statusMessage = "Analyzing take (extracting poses & scoring)..."

            guard let output = await self.camera.finishRecording() else {
                self.phase = .idle
                self.statusMessage = "Camera recording failed."
                return
            }

            // 4. Refuse to grade if incompatible, but keep playback functional
            if let refusal = self.gradingRefusalReason {
                self.phase = .results
                self.statusMessage = "Take finished. Grading skipped: \(refusal)"
                self.showResultsSheet = true
                return
            }

            // 5. Post-take pose extraction
            await self.processAndScoreTake(output: output, videoStartHostSeconds: videoStartHostSeconds)
        }
    }

    public func abortTake() {
        takeExecutionTask?.cancel()
        takeExecutionTask = nil
        countInTask?.cancel()
        metronome.stop()
        camera.cancelRecording()
        player.pause()
        isPlaying = false
        isCountIn = false
        phase = .idle
        statusMessage = "Take cancelled."
    }

    private func processAndScoreTake(output: TakeRecorder.Output, videoStartHostSeconds: Double) async {
        do {
            let rawFrames = try await extractPoses(output.url)
            try? FileManager.default.removeItem(at: output.url)

            guard rawFrames.count >= 10 else {
                phase = .idle
                statusMessage = "No dancer found in take: step back so your full body is in frame."
                return
            }

            // Rebase extracted frames onto the video start timeline
            let t0 = rawFrames.first?.t ?? 0.0
            let shift = output.firstFrameHostSeconds - videoStartHostSeconds
            let takeFrames = rawFrames.compactMap { frame -> GrooveScoringEngine.RawPoseFrame? in
                let t = (frame.t - t0) + shift
                guard t >= 0.0 else { return nil }
                return GrooveScoringEngine.RawPoseFrame(
                    t: t,
                    joints: frame.joints,
                    confidences: frame.confidences,
                    hands: frame.hands
                )
            }

            // Mirror semantics per spec §2.2:
            // Default flipped teacher video -> learner copies anatomical same side -> scoring mirrored = false.
            // "As Filmed" toggle -> learner mirrors screen opposite side -> scoring mirrored = true.
            let scoringMirrored = !isMirrored

            let policy = segment.adaptiveSpeed ?? manifest.practice.adaptiveSpeed
            let refClip = LessonStore.shared.loadReferenceClip(for: manifest)
            let refFrames = refClip?.frames ?? []

            // Slice & stretch reference
            let sliced = try LessonPackage.sliceReference(
                frames: refFrames,
                manifest: manifest,
                segmentID: segment.id
            )
            let stretched = try LessonPackage.stretch(sliced, rate: playbackRate, policy: policy)

            // Convert windows
            let scoringWindows = stretched.windows.map { w in
                GrooveScoringEngine.ScoringWindow(
                    kind: w.kind,
                    start_s: w.startS,
                    end_s: w.endS,
                    mask: w.mask,
                    tolerance_scale: w.toleranceScale
                )
            }

            let refPoseClip = GrooveScoringEngine.PoseClip(
                clip_id: stretched.clipID,
                move_tag: stretched.moveTag,
                bpm: stretched.bpm,
                beat_times: stretched.beatTimes,
                gravity_vector: stretched.gravityVector,
                mirrored: stretched.mirrored,
                audio_latency_ms: stretched.audioLatencyMs,
                speed_pct: stretched.speedPct,
                frames: stretched.frames,
                windows: scoringWindows
            )

            let takePoseClip = GrooveScoringEngine.PoseClip(
                clip_id: "take_\(manifest.lessonSlug)_\(segment.id)_\(takeCounter)",
                move_tag: segment.id,
                bpm: stretched.bpm,
                beat_times: stretched.beatTimes,
                gravity_vector: [0.0, -1.0, 0.0],
                mirrored: scoringMirrored,
                audio_latency_ms: metronome.outputLatencyMs,
                speed_pct: Int((playbackRate * 100.0).rounded()),
                frames: takeFrames
            )

            // Deep-merge config overrides: bundled config < lesson < segment
            let baseData = GrooveLibrary.loadBundledConfigData()
            let baseJSON = try LessonPackage.JSONValue.parse(baseData)
            let mergedJSON = try LessonPackage.segmentConfig(config: baseJSON, manifest: manifest, segmentID: segment.id)
            let scoringConfig = try mergedJSON.decoded(as: GrooveScoringEngine.GrooveConfig.self)

            // Score attempt
            let scoreResult = GrooveScoringEngine.scoreAttempt(
                attempt: takePoseClip,
                reference: refPoseClip,
                config: scoringConfig
            )

            self.latestScoreResult = scoreResult
            self.latestTakeClip = takePoseClip
            self.latestRefClip = refPoseClip
            self.latestResultPose = PracticeViewModel.displayPose(
                take: takePoseClip,
                at: stretched.beatTimes.first ?? 0.0,
                mirrored: scoringMirrored
            )

            // Record take in adaptive speed ladder
            recordTake(passed: scoreResult.passed, rate: playbackRate)

            phase = .results
            statusMessage = scoreResult.passed ? "Pass! Progress saved." : "Take scored. Keep drilling!"
            showResultsSheet = true
        } catch {
            phase = .idle
            statusMessage = "Scoring error: \(error.localizedDescription)"
        }
    }

    // MARK: - Adaptive Speed Ladder

    public func simulateTake(passed: Bool) {
        recordTake(passed: passed, rate: playbackRate)
        statusMessage = "Simulated \(passed ? "PASS" : "FAIL") at \(String(format: "%.2fx", playbackRate))."
    }

    public func setRateManually(_ rate: Double) {
        playbackRate = rate
        if isPlaying {
            player.rate = Float(rate)
        }
        // Manual rate selection moves ladder (spec §8 Q6)
        recordTake(passed: false, rate: rate)
    }

    public func resetHistory() {
        takeHistory.removeAll()
        LessonStore.shared.clearTakes(lessonID: manifest.lessonID, version: manifest.packageVersion, segmentID: segment.id)
        let policy = segment.adaptiveSpeed ?? manifest.practice.adaptiveSpeed
        playbackRate = policy.startRate
        nextSegmentUnlocked = false
        statusMessage = "Take history reset."
    }

    private func recordTake(passed: Bool, rate: Double) {
        LessonStore.shared.saveTake(
            lessonID: manifest.lessonID,
            version: manifest.packageVersion,
            segmentID: segment.id,
            passed: passed,
            rate: rate
        )
        self.takeHistory = LessonStore.shared.loadTakes(
            lessonID: manifest.lessonID,
            version: manifest.packageVersion,
            segmentID: segment.id
        )

        let policy = segment.adaptiveSpeed ?? manifest.practice.adaptiveSpeed
        if let (newRate, unlocked) = try? LessonPackage.nextRate(policy: policy, history: takeHistory) {
            self.playbackRate = newRate
            self.nextSegmentUnlocked = unlocked
        }
    }

    // MARK: - Attempt Export (Spec §5 V4)

    public func exportAttemptBundle() {
        guard let scoreResult = latestScoreResult else { return }
        let policy = segment.adaptiveSpeed ?? manifest.practice.adaptiveSpeed
        let refFrames = LessonStore.shared.loadReferenceClip(for: manifest)?.frames ?? []
        let sliced = try? LessonPackage.sliceReference(frames: refFrames, manifest: manifest, segmentID: segment.id)
        let stretched = try? sliced.flatMap { try? LessonPackage.stretch($0, rate: playbackRate, policy: policy) }

        let refClip: GrooveScoringEngine.PoseClip
        if let latest = latestRefClip {
            refClip = latest
        } else if let stretched {
            let win = stretched.windows.map { w in
                GrooveScoringEngine.ScoringWindow(
                    kind: w.kind,
                    start_s: w.startS,
                    end_s: w.endS,
                    mask: w.mask,
                    tolerance_scale: w.toleranceScale
                )
            }
            refClip = GrooveScoringEngine.PoseClip(
                clip_id: stretched.clipID,
                move_tag: stretched.moveTag,
                bpm: stretched.bpm,
                beat_times: stretched.beatTimes,
                gravity_vector: stretched.gravityVector,
                mirrored: stretched.mirrored,
                audio_latency_ms: stretched.audioLatencyMs,
                speed_pct: stretched.speedPct,
                frames: stretched.frames,
                windows: win
            )
        } else {
            return
        }

        let takeClip: GrooveScoringEngine.PoseClip
        if let latest = latestTakeClip {
            takeClip = latest
        } else {
            takeClip = GrooveScoringEngine.PoseClip(
                clip_id: "take_\(manifest.lessonSlug)_\(segment.id)_\(takeCounter)",
                move_tag: segment.id,
                bpm: refClip.bpm,
                beat_times: refClip.beat_times,
                gravity_vector: [0.0, -1.0, 0.0],
                mirrored: !isMirrored,
                audio_latency_ms: metronome.outputLatencyMs,
                speed_pct: Int((playbackRate * 100.0).rounded()),
                frames: []
            )
        }

        let bundle = AttemptExport.AttemptBundle(
            lessonId: manifest.lessonID,
            segmentId: segment.id,
            packageVersion: manifest.packageVersion,
            rate: playbackRate,
            mirrored: !isMirrored,
            takePoses: takeClip,
            referenceSlice: refClip,
            result: scoreResult
        )

        if let fileURL = try? AttemptExport.exportBundleToFile(bundle) {
            self.shareURL = fileURL
            self.showShareSheet = true
        }
    }

    // MARK: - Internal Player Setup

    private func setupPlayer() {
        guard let url = videoURL, FileManager.default.fileExists(atPath: url.path) else {
            return
        }

        let item = AVPlayerItem(url: url)
        // Spec §2.4: pitch-preserving algorithm
        item.audioTimePitchAlgorithm = .timeDomain
        player.replaceCurrentItem(with: item)
        // Spec §2.4: minimize stalling
        player.automaticallyWaitsToMinimizeStalling = false

        let interval = CMTime(value: 1, timescale: 30)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                self?.handlePlaybackTimeUpdate(time: time)
            }
        }
    }

    @MainActor
    private func handlePlaybackTimeUpdate(time: CMTime) {
        guard !isTakingTake else { return }
        let t = CMTimeGetSeconds(time)

        // Loop check in review mode
        if t >= segment.endS {
            if isLooping {
                player.seek(
                    to: CMTime(seconds: segment.startS, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                )
                player.play()
                player.rate = Float(playbackRate)
            } else {
                pausePlayback()
            }
            return
        }

        // Update 1..8 beat counter from beatGrid
        if let activeBeat = segmentBeats.last(where: { $0.t <= (t + 0.05) }) {
            currentBeatCount = activeBeat.count
            currentPhrase = activeBeat.phrase
        }
    }
}

// MARK: - UIKit AVPlayerLayer Host (Mirroring View)

public struct PlayerLayerView: UIViewRepresentable {
    public let player: AVPlayer
    public let isMirrored: Bool

    public func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView(player: player)
        view.setMirrored(isMirrored)
        return view
    }

    public func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.player = player
        uiView.setMirrored(isMirrored)
    }
}

public final class PlayerUIView: UIView {
    public var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }

    override public static var layerClass: AnyClass { AVPlayerLayer.self }
    public var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    public init(player: AVPlayer) {
        super.init(frame: .zero)
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func setMirrored(_ mirrored: Bool) {
        transform = mirrored ? CGAffineTransform(scaleX: -1.0, y: 1.0) : .identity
    }
}
