import AVFoundation
import Combine
import CoreMedia
import GrooveCore
import SwiftUI
import UIKit

/// Player view for learning and practicing a lesson segment end to end (spec §2.4, §8 Q6):
/// - Teacher AVPlayer with pitch-preserving algorithm (`audioTimePitchAlgorithm = .timeDomain`),
/// - Starts takes with sample-accurate host-time synchronization using Metronome and `player.setRate(atHostTime:)`,
/// - Pre-take calibration (level the phone, full body in frame, T-pose; skippable) before the count-in,
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
        CoordinatorStageObserver(coordinator: viewModel.coordinator) {
            ZStack {
                Color(red: 0, green: 0, blue: 0).ignoresSafeArea()

                if viewModel.coordinator.shouldShowPhoneControllerStatus {
                    phoneControllerStageView
                } else {
                    phoneFullPlayerView
                }
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

    // MARK: - Phone Controller Mode (TV Stage Active / Awaiting AirPlay Reconnect)

    private var phoneControllerStageView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.subheadline.weight(.bold))
                        Text("Exit Lesson")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(Color.white.opacity(0.68))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.06), in: Capsule())
                }

                Spacer()

                Text("Segment \(viewModel.segment.id) · \(String(format: "%.2fx", viewModel.playbackRate))")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.48))
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            viewModel.coordinator.makePhoneControllerStatusView(
                title: viewModel.segment.title,
                statusText: viewModel.statusMessage.isEmpty ? nil : viewModel.statusMessage,
                onPauseResume: {
                    viewModel.handlePhoneControllerPauseResume()
                },
                onSkipCalibration: {
                    viewModel.calibration.skip()
                }
            )
        }
    }

    private var phoneFullPlayerView: some View {
        VStack(spacing: 0) {
            // Top navigation bar
            topNavigationBar

            // Viewport area
            ZStack {
                if viewModel.isTakingTake {
                    // Take Mode: Camera active with live overlay and PIP of teacher video
                    takeViewportView
                } else {
                    // Review Mode: Full teacher video with beat indicators
                    reviewViewportView
                }

                // Count-in HUD
                if viewModel.isCountIn {
                    countInOverlay
                }

                // Paused HUD
                if viewModel.phase == .paused {
                    pausedOverlay
                }

                // Hands-free gesture toast + pre-trigger hold ring on phone
                PhoneGestureHUD(
                    camera: viewModel.camera,
                    coordinator: viewModel.coordinator,
                    phase: viewModel.phase.coachingPhase
                )

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

            if viewModel.phase == .calibrating {
                CalibrationOverlayView(
                    controller: viewModel.calibration,
                    imageAspect: viewModel.camera.skeleton.imageAspect
                )
            }

            // Picture-in-picture of teacher video (hidden while calibrating: the HUD needs the corner for Skip)
            if viewModel.hasVideo && viewModel.phase != .calibrating {
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
            if viewModel.phase == .countIn || viewModel.phase == .recording {
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

            if viewModel.coordinator.isExternalDisplayConnected && viewModel.coordinator.isPhoneScreenForced {
                Button {
                    viewModel.coordinator.resumeTVStage()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "tv.fill")
                        Text("TV Stage")
                            .font(.caption.bold())
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.cyan.opacity(0.35), in: Capsule())
                    .foregroundStyle(.white)
                }
            }

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

    private var pausedOverlay: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 12) {
                Label("TAKE PAUSED", systemImage: "pause.circle.fill")
                    .font(.title3.weight(.heavy))
                    .foregroundStyle(.orange)
                Text(
                    viewModel.statusMessage.isEmpty
                        ? "Clap or hold both hands up to resume, or swipe left for review."
                        : viewModel.statusMessage
                )
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

                HStack(spacing: 12) {
                    Button {
                        viewModel.startTake()
                    } label: {
                        Label("Resume Take", systemImage: "play.fill")
                            .font(.subheadline.bold())
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)

                    Button {
                        viewModel.returnToReview()
                    } label: {
                        Text("Back to Review")
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                }
                .padding(.top, 4)
            }
            .padding(20)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
            .padding(.horizontal, 24)
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
                        let target: LessonPlayerViewModel.Phase = (viewModel.phase == .calibrating) ? .idle : .paused
                        let msg = (target == .paused)
                            ? "Take paused. Clap or raise both hands to resume."
                            : "Calibration cancelled."
                        viewModel.abortTake(to: target, message: msg)
                    } else {
                        viewModel.startTake()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(
                            systemName: viewModel.isTakingTake
                                ? "stop.fill"
                                : (viewModel.phase == .paused ? "play.circle.fill" : "record.circle.fill")
                        )
                        .foregroundStyle(viewModel.isTakingTake ? .red : (viewModel.phase == .paused ? .orange : .yellow))
                        Text(
                            viewModel.isTakingTake
                                ? "Stop Take"
                                : (viewModel.phase == .paused ? "Resume Take" : "Start Take")
                        )
                        .font(.subheadline.bold())
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        viewModel.isTakingTake
                            ? Color.red.opacity(0.25)
                            : (viewModel.phase == .paused ? Color.orange.opacity(0.25) : Color.yellow.opacity(0.25)),
                        in: Capsule()
                    )
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

                // Testing, camera & studio actions menu
                Menu {
                    if viewModel.canAdvanceToNextSegment {
                        Button("Next Segment") { viewModel.advanceToNextSegment() }
                    }
                    Button(
                        viewModel.coordinator.cameraMode.isRear
                            ? "Switch to Front Camera"
                            : "Switch to Rear Camera + LiDAR"
                    ) {
                        viewModel.coordinator.toggleCameraMode()
                    }
                    Button("Recalibrate Studio (9 Poses)") {
                        viewModel.requestRecalibrateStudio()
                    }
                    Divider()
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

                        if viewModel.canAdvanceToNextSegment {
                            Button {
                                viewModel.showResultsSheet = false
                                viewModel.advanceToNextSegment()
                            } label: {
                                Label("Next Segment", systemImage: "arrow.right")
                                    .font(.subheadline.bold())
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                        }

                        Button {
                            viewModel.showResultsSheet = false
                            viewModel.returnToReview()
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

// MARK: - Reactive Coordinator & Phone Gesture HUD Helpers

@MainActor
private struct CoordinatorStageObserver<Content: View>: View {
    @ObservedObject var coordinator: CoachingStageCoordinator
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
    }
}

@MainActor
private struct PhoneGestureHUD: View {
    @ObservedObject var camera: PracticeCamera
    @ObservedObject var coordinator: CoachingStageCoordinator
    let phase: CoachingPhase

    var body: some View {
        VStack(spacing: 8) {
            if let toast = coordinator.toastText, !toast.isEmpty {
                GestureToast(text: toast, tvScale: false)
            }
            if phase != .calibrating {
                GestureHoldRingView(
                    progress: camera.gestureHoldProgress,
                    phase: phase,
                    tvScale: false
                )
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.2), value: coordinator.toastText)
    }
}

// MARK: - View Model

@MainActor
final class LessonPlayerViewModel: ObservableObject {
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
            guard phase != oldValue else { return }
            coordinator.setPhase(
                phase.coachingPhase,
                passed: latestScoreResult?.passed,
                nextUnlocked: nextSegmentUnlocked
            )
        }
    }
    @Published private(set) var segment: LessonPackage.Segment
    @Published var isPlaying: Bool = false
    @Published var isCountIn: Bool = false
    @Published var isMirrored: Bool = true {
        didSet {
            guard isMirrored != oldValue else { return }
            coordinator.updateStage(isTeacherMirrored: isMirrored)
        }
    }
    @Published var isLooping: Bool = true
    @Published var countInBeatsLeft: Int = 4 {
        didSet {
            guard countInBeatsLeft != oldValue else { return }
            coordinator.updateStage(countInBeatsLeft: countInBeatsLeft)
        }
    }
    @Published var currentBeatCount: Int = 1 {
        didSet {
            guard currentBeatCount != oldValue else { return }
            coordinator.updateStage(currentBeatCount: currentBeatCount)
        }
    }
    @Published var currentPhrase: Int = 1 {
        didSet {
            guard currentPhrase != oldValue else { return }
            coordinator.updateStage(currentPhrase: currentPhrase)
        }
    }
    @Published var playbackRate: Double = 0.70 {
        didSet {
            guard playbackRate != oldValue else { return }
            coordinator.updateStage(playbackRate: playbackRate)
        }
    }
    @Published var nextSegmentUnlocked: Bool = false {
        didSet {
            guard nextSegmentUnlocked != oldValue else { return }
            coordinator.updateStage(nextUnlocked: nextSegmentUnlocked)
        }
    }
    @Published var takeHistory: [LessonPackage.Take] = []
    @Published var statusMessage: String = "" {
        didSet {
            guard statusMessage != oldValue else { return }
            coordinator.setStatusMessage(statusMessage.isEmpty ? nil : statusMessage)
        }
    }
    @Published var latestScoreResult: GrooveScoringEngine.AttemptScoreResult?
    @Published var latestTakeClip: GrooveScoringEngine.PoseClip?
    @Published var latestRefClip: GrooveScoringEngine.PoseClip?
    @Published var latestResultPose: [String: CGPoint] = [:]
    @Published var gradingRefusalReason: String?
    @Published var showResultsSheet: Bool = false
    @Published var showShareSheet: Bool = false
    @Published var shareURL: URL?

    let manifest: LessonPackage.Manifest
    let videoURL: URL?
    let player = AVPlayer()
    let camera = PracticeCamera()
    /// Pre-take calibration; also owns this screen's motion stream (gravity for the take).
    let calibration = CalibrationController(screen: "lesson")
    /// Shared TV stage, camera-mode, AirPlay-drop, `GestureRouter`, and `CalibrationProfileStore` coordinator.
    let coordinator = CoachingStageCoordinator(host: .lesson)
    let extractPoses: @Sendable (URL) async throws -> [GrooveScoringEngine.RawPoseFrame]

    private let metronome = Metronome()
    private var timeObserverToken: Any?
    private var countInTask: Task<Void, Never>?
    private var takeExecutionTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var segmentBeats: [LessonPackage.Beat] = []
    private var takeCounter = 0
    /// Skip is remembered for the rest of this visit (later takes go straight to the count-in).
    private var calibrationSkipped = false
    /// Calibration of the current take: frames + v2 scoring payload (nil when skipped), camera-frame gravity, and audio latency.
    private var takeCalibrationFrames: [GrooveScoringEngine.RawPoseFrame]?
    private var takeCalibrationV2: LearnerCalibrationV2?
    private var takeGravity: [Double]?
    private var takeAudioLatencyMs: Double?

    var hasVideo: Bool {
        guard let url = videoURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    var isTakingTake: Bool {
        phase == .calibrating || phase == .countIn || phase == .recording
    }

    var orderedSegments: [LessonPackage.Segment] {
        manifest.segments.sorted { $0.teachOrder < $1.teachOrder }
    }

    var nextOrderedSegment: LessonPackage.Segment? {
        let ordered = orderedSegments
        guard let idx = ordered.firstIndex(where: { $0.id == segment.id }),
              idx + 1 < ordered.count else {
            return nil
        }
        return ordered[idx + 1]
    }

    var canAdvanceToNextSegment: Bool {
        nextSegmentUnlocked && nextOrderedSegment != nil
    }

    var adaptiveStatusText: String {
        let policy = segment.adaptiveSpeed ?? manifest.practice.adaptiveSpeed
        return "Ladder: [\(String(format: "%.1f", policy.minRate))x - \(String(format: "%.1f", policy.maxRate))x] • Takes: \(takeHistory.count)"
    }

    static let defaultExtractPoses: @Sendable (URL) async throws -> [GrooveScoringEngine.RawPoseFrame] = { url in
        try await VideoPoseExtractor.extractFrames(from: url, rebaseToFirstSample: false)
    }

    init(
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

        setupCoordinator()
        setupPlayer()
        syncStageMetadata()
    }

    deinit {
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
        }
    }

    nonisolated private static func runOnMainActor(_ block: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                block()
            }
        } else {
            Task { @MainActor in
                block()
            }
        }
    }

    private func setupCoordinator() {
        coordinator.onCommand = { [weak self] command in
            self?.handleCoachingCommand(command)
        }
        coordinator.onAirPlayDropped = { [weak self] in
            self?.handleAirPlayDropped()
        }
        coordinator.onAirPlayReconnected = { [weak self] in
            self?.handleAirPlayReconnected()
        }
        coordinator.onRecalibrateStudioRequested = { [weak self] in
            self?.handleRecalibrateStudioRequested()
        }

        coordinator.objectWillChange
            .sink { [weak self] _ in
                Self.runOnMainActor { [weak self] in
                    self?.objectWillChange.send()
                }
            }
            .store(in: &cancellables)

        coordinator.$phase
            .removeDuplicates()
            .sink { [weak self] coordPhase in
                Self.runOnMainActor { [weak self] in
                    guard let self else { return }
                    if coordPhase == .paused && self.phase == .calibrating {
                        self.abortTake(
                            to: .paused,
                            message: "Calibration paused. Tap Resume Take or raise both hands to continue."
                        )
                    }
                }
            }
            .store(in: &cancellables)

        coordinator.$isPhoneScreenForced
            .removeDuplicates()
            .sink { [weak self] forced in
                Self.runOnMainActor { [weak self] in
                    guard let self, forced else { return }
                    if self.phase == .results && (self.latestScoreResult != nil || self.gradingRefusalReason != nil) {
                        self.showResultsSheet = true
                    }
                }
            }
            .store(in: &cancellables)
    }

    private func syncStageMetadata() {
        let subtitle = "Segment \(segment.id) • \(String(format: "%.1f–%.1fs", segment.startS, segment.endS))"
        coordinator.setPlayer(player, hasTeacherVideo: hasVideo)
        coordinator.updateStage(
            title: segment.title,
            subtitle: subtitle,
            playbackRate: playbackRate,
            isTeacherMirrored: isMirrored,
            hasTeacherVideo: hasVideo,
            countInBeatsLeft: countInBeatsLeft,
            currentBeatCount: currentBeatCount,
            currentPhrase: currentPhrase,
            nextUnlocked: nextSegmentUnlocked,
            statusMessage: statusMessage.isEmpty ? nil : statusMessage
        )
    }

    func onAppear() {
        UIApplication.shared.isIdleTimerDisabled = true
        calibrationSkipped = false
        // Camera and motion run for the whole visit so calibration and gestures work immediately.
        calibration.startSensors()
        if camera.deviceGravityProvider == nil {
            let motionSensors = calibration.sensors
            camera.deviceGravityProvider = { [weak motionSensors] in
                motionSensors?.currentGravity() ?? [0.0, -1.0, 0.0]
            }
        }
        syncStageMetadata()
        coordinator.setPhase(
            phase.coachingPhase,
            passed: latestScoreResult?.passed,
            nextUnlocked: nextSegmentUnlocked
        )
        coordinator.attach(
            camera: camera,
            calibration: calibration,
            player: player,
            host: .lesson
        )
        Task { @MainActor [weak self] in
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard let self else { return }
            if granted {
                self.camera.start()
            } else {
                self.statusMessage = "Camera access is off: enable it in Settings > Groove Coach."
            }
        }
        restartWithCountIn()
    }

    func onDisappear() {
        UIApplication.shared.isIdleTimerDisabled = false
        takeExecutionTask?.cancel()
        takeExecutionTask = nil
        if phase != .idle {
            phase = .idle
        }
        calibration.stopSensors()
        stopPlayback()
        camera.cancelRecording()
        camera.stop()
        coordinator.detach()
    }

    func toggleMirror() {
        isMirrored.toggle()
    }

    func togglePlayPause() {
        if isPlaying {
            pausePlayback()
        } else {
            restartWithCountIn()
        }
    }

    // MARK: - Hands-Free Gesture Commands, AirPlay Lifecycle & Phone Controller Actions

    func handleCoachingCommand(_ command: CoachingCommand) {
        switch command {
        case .startTake:
            showResultsSheet = false
            startTake()

        case .pauseTake:
            abortTake(to: .paused, message: "Take paused. Clap or raise both hands to resume.")

        case .togglePreviewPlayPause:
            togglePlayPause()

        case .restartPreview:
            if hasVideo {
                restartWithCountIn()
            } else {
                statusMessage = "Video not downloaded."
            }

        case .nextItem:
            showResultsSheet = false
            advanceToNextSegment()

        case .returnToReview:
            returnToReview()

        case .repeatCalibrationCue, .skipCalibration:
            // Executed directly on `CalibrationController` by `CoachingStageCoordinator` prior to `onCommand`.
            break
        }
    }

    func handlePhoneControllerPauseResume() {
        switch phase {
        case .countIn, .recording:
            abortTake(to: .paused, message: "Take paused. Tap Resume Take or raise both hands to continue.")
        case .calibrating:
            abortTake(to: .paused, message: "Calibration paused. Tap Resume Take or raise both hands to restart.")
        case .paused, .idle, .results:
            if !coordinator.isExternalDisplayConnected {
                coordinator.usePhoneScreenFrontCamera()
            }
            showResultsSheet = false
            startTake()
        case .analyzing:
            break
        }
    }

    private func handleAirPlayDropped() {
        let droppedPhase = coordinator.lastAirPlayDropPhase ?? phase.coachingPhase
        let notice = (droppedPhase == .calibrating || droppedPhase == .clapSync)
            ? CalibrationVoice.airPlayDisconnectedMidCalibrationText
            : CalibrationVoice.airPlayDisconnectedMidTakeText
        showResultsSheet = false
        // §4.3: Abort into `.paused` without calling `recordTake(passed: false, ...)` so an AirPlay drop
        // never demotes the learner on the adaptive speed ladder.
        abortTake(to: .paused, message: notice)
    }

    private func handleAirPlayReconnected() {
        statusMessage = CalibrationVoice.airPlayReconnectedText
    }

    private func handleRecalibrateStudioRequested() {
        calibrationSkipped = false
        statusMessage = "Studio recalibration queued for your next take."
    }

    func requestRecalibrateStudio() {
        calibrationSkipped = false
        coordinator.profileStore.requestFullRecalibration()
        if phase == .calibrating {
            startTake()
        } else {
            statusMessage = "Full 9-pose studio calibration will run on your next take."
        }
    }

    func returnToReview(message: String = "Back to lesson review.") {
        showResultsSheet = false
        if phase != .idle {
            abortTake(to: .idle, message: message)
        } else {
            statusMessage = message
        }
        if hasVideo {
            restartWithCountIn()
        }
    }

    func advanceToNextSegment() {
        guard nextSegmentUnlocked else {
            returnToReview(message: "Pass this segment to unlock the next part.")
            return
        }
        guard let nextSeg = nextOrderedSegment else {
            returnToReview(message: "Lesson complete! Reviewing \(segment.title).")
            return
        }

        showResultsSheet = false
        takeExecutionTask?.cancel()
        takeExecutionTask = nil
        calibration.cancel()
        stopPlayback()
        camera.cancelRecording()

        latestScoreResult = nil
        latestTakeClip = nil
        latestRefClip = nil
        latestResultPose = [:]
        gradingRefusalReason = nil
        coordinator.clearTakeResults()

        self.segment = nextSeg
        let policy = nextSeg.adaptiveSpeed ?? manifest.practice.adaptiveSpeed
        let savedTakes = LessonStore.shared.loadTakes(
            lessonID: manifest.lessonID,
            version: manifest.packageVersion,
            segmentID: nextSeg.id
        )
        self.takeHistory = savedTakes
        if let result = try? LessonPackage.nextRate(policy: policy, history: savedTakes) {
            self.playbackRate = result.rate
            self.nextSegmentUnlocked = result.unlocked
        } else {
            self.playbackRate = policy.startRate
            self.nextSegmentUnlocked = false
        }

        self.segmentBeats = manifest.beatGrid.beats.filter {
            $0.t >= (nextSeg.startS - 0.05) && $0.t <= (nextSeg.endS + 0.05)
        }
        self.currentBeatCount = segmentBeats.first?.count ?? 1
        self.currentPhrase = segmentBeats.first?.phrase ?? 1
        self.phase = .idle
        self.statusMessage = "Segment \(nextSeg.id): \(nextSeg.title)"
        syncStageMetadata()

        if hasVideo {
            restartWithCountIn()
        }
    }

    // MARK: - Review Playback Flow

    func restartWithCountIn() {
        guard hasVideo, phase != .calibrating else { return }
        if phase == .paused {
            phase = .idle
        }
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

        let videoMachTime = scheduledVideoMachTime(
            audioStartMachTime: startInfo.machTime,
            countInDuration: countInDuration
        )
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

    func pausePlayback() {
        metronome.stop()
        countInTask?.cancel()
        isCountIn = false
        player.pause()
        isPlaying = false
    }

    func stopPlayback() {
        pausePlayback()
    }

    // MARK: - Take Flow (Spec §2.4)

    func startTake() {
        showResultsSheet = false
        stopPlayback()
        takeExecutionTask?.cancel()
        takeExecutionTask = nil
        calibration.cancel()
        coordinator.clearTakeResults()
        camera.start()

        if coordinator.consumePendingRecalibrateStudioRequest(applyingTo: calibration) {
            calibrationSkipped = false
        }

        guard !calibrationSkipped else {
            beginTakeCountIn(outcome: nil)
            return
        }
        phase = .calibrating
        statusMessage = "Calibrating: follow the voice, or double-clap / tap Skip."
        calibration.begin(camera: camera) { [weak self] outcome in
            guard let self, self.phase == .calibrating else { return }
            if outcome.skipped {
                self.calibrationSkipped = true
                self.beginTakeCountIn(outcome: outcome)
                return
            }
            self.statusMessage = outcome.resumed ? "Setup unchanged. Locked in!" : "Locked in!"
            // Let "Locked in!" finish before the count-in clicks.
            self.takeExecutionTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled, self.phase == .calibrating else { return }
                self.beginTakeCountIn(outcome: outcome)
            }
        }
    }

    /// Count-in, record and score one take. `outcome` carries the locked calibration (`nil` on subsequent skipped takes).
    private func beginTakeCountIn(outcome: CalibrationController.Outcome?) {
        takeExecutionTask?.cancel()
        takeExecutionTask = nil
        phase = .countIn
        statusMessage = "Starting take..."

        let isSkipped = calibrationSkipped || (outcome?.skipped == true)
        takeCalibrationFrames = isSkipped ? nil : outcome?.profile?.frames
        takeCalibrationV2 = coordinator.scoringCalibration(
            skipped: isSkipped,
            outcomeProfileV2: outcome?.profileV2
        )
        takeGravity = outcome?.cameraGravity ?? calibration.currentCameraGravity(for: camera.activeCameraMode)

        // Check model compatibility guard (spec §2.2)
        let (_, refusalReason) = AttemptExport.canGrade(manifest: manifest)
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
            phase = .idle
            statusMessage = "Audio error: \(error.localizedDescription)"
            return
        }

        takeAudioLatencyMs = coordinator.effectiveAudioLatencyMs(baseOutputLatencyMs: metronome.outputLatencyMs)

        // §4.2: shift `videoMachTime` by `-coordinator.tvVideoLeadOffsetSeconds` when TV stage is active,
        // keeping `videoStartHostSeconds` anchored at `startInfo.hostSeconds + countInDuration` (`T0`).
        let videoMachTime = scheduledVideoMachTime(
            audioStartMachTime: startInfo.machTime,
            countInDuration: countInDuration
        )
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
            self.countInBeatsLeft = 0
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
                guard !Task.isCancelled, self.phase == .analyzing else { return }
                self.phase = .idle
                self.statusMessage = "Camera recording failed."
                return
            }

            guard !Task.isCancelled, self.phase == .analyzing else {
                try? FileManager.default.removeItem(at: output.url)
                return
            }

            // 4. Refuse to grade if incompatible, but keep playback functional
            if let refusal = self.gradingRefusalReason {
                try? FileManager.default.removeItem(at: output.url)
                self.coordinator.setScoreResult(nil, resultPose: [:], gradingRefusalReason: refusal)
                self.phase = .results
                self.statusMessage = "Take finished. Grading skipped: \(refusal)"
                self.showResultsSheet = !self.coordinator.shouldShowPhoneControllerStatus
                return
            }

            // 5. Post-take pose extraction
            await self.processAndScoreTake(output: output, videoStartHostSeconds: videoStartHostSeconds)
        }
    }

    /// Shifts `audioStartMachTime + countInDuration` by `-coordinator.tvVideoLeadOffsetSeconds` when the TV stage is active (§4.2).
    private func scheduledVideoMachTime(audioStartMachTime: UInt64, countInDuration: Double) -> UInt64 {
        let leadOffsetSeconds = coordinator.tvVideoLeadOffsetSeconds
        let netVideoDelaySeconds = countInDuration - leadOffsetSeconds
        if netVideoDelaySeconds >= 0 {
            return audioStartMachTime &+ AVAudioTime.hostTime(forSeconds: netVideoDelaySeconds)
        } else {
            let advanceTicks = AVAudioTime.hostTime(forSeconds: -netVideoDelaySeconds)
            return audioStartMachTime > advanceTicks ? (audioStartMachTime - advanceTicks) : 0
        }
    }

    func abortTake(to targetPhase: Phase = .idle, message: String? = nil) {
        let wasCalibrating = (phase == .calibrating) || calibration.isRunning
        takeExecutionTask?.cancel()
        takeExecutionTask = nil
        calibration.cancel()
        if wasCalibrating {
            calibration.unlockExposure()
        }
        countInTask?.cancel()
        countInTask = nil
        metronome.stop()
        camera.cancelRecording()
        player.pause()
        isPlaying = false
        isCountIn = false
        countInBeatsLeft = 0
        phase = targetPhase
        if let message {
            statusMessage = message
        } else {
            statusMessage = (targetPhase == .paused) ? "Take paused." : "Take cancelled."
        }
    }

    private func processAndScoreTake(output: TakeRecorder.Output, videoStartHostSeconds: Double) async {
        do {
            let rawFrames = try await extractPoses(output.url)
            try? FileManager.default.removeItem(at: output.url)
            guard !Task.isCancelled, phase == .analyzing else { return }

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

            let effectiveAudioLatencyMs = takeAudioLatencyMs
                ?? coordinator.effectiveAudioLatencyMs(baseOutputLatencyMs: metronome.outputLatencyMs)
            let resolvedCalibrationV2 = takeCalibrationV2
                ?? coordinator.scoringCalibration(skipped: calibrationSkipped)

            let takePoseClip = GrooveScoringEngine.PoseClip(
                clip_id: "take_\(manifest.lessonSlug)_\(segment.id)_\(takeCounter)",
                move_tag: segment.id,
                bpm: stretched.bpm,
                beat_times: stretched.beatTimes,
                gravity_vector: takeGravity ?? calibration.currentCameraGravity(for: camera.activeCameraMode),
                mirrored: scoringMirrored,
                audio_latency_ms: effectiveAudioLatencyMs,
                speed_pct: Int((playbackRate * 100.0).rounded()),
                frames: takeFrames,
                calibration_frames: takeCalibrationFrames,
                calibration_v2: resolvedCalibrationV2
            )

            // Deep-merge config overrides: bundled config < lesson < segment
            let baseData = GrooveLibrary.loadBundledConfigData()
            let baseJSON = try LessonPackage.JSONValue.parse(baseData)
            let mergedJSON = try LessonPackage.segmentConfig(config: baseJSON, manifest: manifest, segmentID: segment.id)
            let scoringConfig = try mergedJSON.decoded(as: GrooveScoringEngine.GrooveConfig.self)

            // Score attempt
            let takenRate = playbackRate
            let scoreResult = GrooveScoringEngine.scoreAttempt(
                attempt: takePoseClip,
                reference: refPoseClip,
                config: scoringConfig
            )
            guard !Task.isCancelled, phase == .analyzing else { return }

            var summary = PracticeViewModel.takeSummary(scoreResult, take: takePoseClip)
            summary["lessonId"] = manifest.lessonID
            summary["segmentId"] = segment.id
            summary["rate"] = takenRate
            summary["cameraMode"] = coordinator.cameraMode.rawValue
            summary["audioLatencyMs"] = effectiveAudioLatencyMs
            summary["hasCalibrationV2"] = (resolvedCalibrationV2 != nil)
            DebugLog.info("take_end lesson \(manifest.lessonID) segment \(segment.id) rate \(takenRate)")
            DebugLink.shared.sendEvent(kind: "take_end", fields: summary)

            self.latestScoreResult = scoreResult
            self.latestTakeClip = takePoseClip
            self.latestRefClip = refPoseClip
            self.latestResultPose = PracticeViewModel.displayPose(
                take: takePoseClip,
                at: stretched.beatTimes.first ?? 0.0,
                mirrored: scoringMirrored
            )

            // Record take in adaptive speed ladder before transitioning to `.results` so `nextSegmentUnlocked` is current.
            recordTake(passed: scoreResult.passed, rate: takenRate)
            coordinator.setScoreResult(scoreResult, resultPose: latestResultPose, gradingRefusalReason: nil)

            phase = .results
            statusMessage = scoreResult.passed ? "Pass! Progress saved." : "Take scored. Keep drilling!"
            showResultsSheet = !coordinator.shouldShowPhoneControllerStatus
        } catch {
            try? FileManager.default.removeItem(at: output.url)
            guard !Task.isCancelled, phase == .analyzing else { return }
            phase = .idle
            statusMessage = "Scoring error: \(error.localizedDescription)"
        }
    }

    // MARK: - Adaptive Speed Ladder

    func simulateTake(passed: Bool) {
        recordTake(passed: passed, rate: playbackRate)
        statusMessage = "Simulated \(passed ? "PASS" : "FAIL") at \(String(format: "%.2fx", playbackRate))."
    }

    func setRateManually(_ rate: Double) {
        playbackRate = rate
        if isPlaying {
            player.rate = Float(rate)
        }
        // Manual rate selection moves ladder (spec §8 Q6)
        recordTake(passed: false, rate: rate)
    }

    func resetHistory() {
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
        if let next = try? LessonPackage.nextRate(policy: policy, history: takeHistory) {
            self.playbackRate = next.rate
            self.nextSegmentUnlocked = next.unlocked
        }
    }

    // MARK: - Attempt Export (Spec §5 V4)

    func exportAttemptBundle() {
        guard let scoreResult = latestScoreResult else { return }
        let policy = segment.adaptiveSpeed ?? manifest.practice.adaptiveSpeed
        let refFrames = LessonStore.shared.loadReferenceClip(for: manifest)?.frames ?? []
        let sliced = try? LessonPackage.sliceReference(frames: refFrames, manifest: manifest, segmentID: segment.id)
        let stretched = sliced.flatMap { try? LessonPackage.stretch($0, rate: playbackRate, policy: policy) }

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
            let effectiveAudioLatencyMs = takeAudioLatencyMs
                ?? coordinator.effectiveAudioLatencyMs(baseOutputLatencyMs: metronome.outputLatencyMs)
            takeClip = GrooveScoringEngine.PoseClip(
                clip_id: "take_\(manifest.lessonSlug)_\(segment.id)_\(takeCounter)",
                move_tag: segment.id,
                bpm: refClip.bpm,
                beat_times: refClip.beat_times,
                gravity_vector: takeGravity ?? calibration.currentCameraGravity(for: camera.activeCameraMode),
                mirrored: !isMirrored,
                audio_latency_ms: effectiveAudioLatencyMs,
                speed_pct: Int((playbackRate * 100.0).rounded()),
                frames: [],
                calibration_frames: takeCalibrationFrames,
                calibration_v2: takeCalibrationV2 ?? coordinator.scoringCalibration(skipped: calibrationSkipped)
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
        // Spec §4.1 / §11.1: keep `AVPlayer` inside the composite 16:9 TV `UIWindowScene` rather than full-screen AirPlay Video.
        player.allowsExternalPlayback = false

        guard let url = videoURL, FileManager.default.fileExists(atPath: url.path) else {
            return
        }

        let item = AVPlayerItem(url: url)
        // Spec §2.4: pitch-preserving algorithm
        item.audioTimePitchAlgorithm = .timeDomain
        player.replaceCurrentItem(with: item)
        // Spec §2.4: minimize stalling
        player.automaticallyWaitsToMinimizeStalling = false
        player.allowsExternalPlayback = false

        let interval = CMTime(value: 1, timescale: 30)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                self?.handlePlaybackTimeUpdate(time: time)
            }
        }
    }

    @MainActor
    private func handlePlaybackTimeUpdate(time: CMTime) {
        let t = CMTimeGetSeconds(time)

        // Update 1..8 beat counter from beatGrid during active takes (`.recording`) and review playback.
        if phase == .recording || !isTakingTake {
            if let activeBeat = segmentBeats.last(where: { $0.t <= (t + 0.05) }) {
                currentBeatCount = activeBeat.count
                currentPhrase = activeBeat.phrase
            }
        }

        guard !isTakingTake else { return }

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
