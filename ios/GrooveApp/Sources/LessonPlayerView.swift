import AVFoundation
import Combine
import SwiftUI
import UIKit

/// Player view for learning and practicing a lesson segment:
/// - AVPlayer with `automaticallyWaitsToMinimizeStalling = false`,
/// - pitch-preserving playback algorithm (`audioTimePitchAlgorithm = .timeDomain`),
/// - count-in clicks driven by the existing `Metronome`,
/// - sample-accurate video start using `player.setRate(rate, time: segment.start_s, atHostTime:)`,
/// - dynamic 1..8 beat counter driven by the lesson's `beat_grid`,
/// - segment loop support,
/// - mirror flip on by default with an "as filmed" toggle,
/// - adaptive rate policy (`nextRate` stub) matching spec §8 Q6.
public struct LessonPlayerView: View {
    @StateObject private var viewModel: LessonPlayerViewModel
    @Environment(\.dismiss) private var dismiss

    public init(
        manifest: LessonManifest,
        segment: LessonManifest.SegmentInfo,
        videoURL: URL?
    ) {
        _viewModel = StateObject(
            wrappedValue: LessonPlayerViewModel(
                manifest: manifest,
                segment: segment,
                videoURL: videoURL
            )
        )
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // Top control bar
                topNavigationBar

                // Video viewport with overlays
                ZStack {
                    if viewModel.hasVideo {
                        PlayerLayerView(player: viewModel.player, isMirrored: viewModel.isMirrored)
                            .clipped()
                    } else {
                        videoPlaceholderView
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
        .onAppear {
            viewModel.onAppear()
        }
        .onDisappear {
            viewModel.onDisappear()
        }
    }

    // MARK: - Subviews

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
                Text("Segment \(viewModel.segment.id) • \(String(format: "%.1f–%.1fs", viewModel.segment.start_s, viewModel.segment.end_s))")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
            }

            Spacer()

            // "As Filmed" vs "Mirrored" flip toggle
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
            Text("Download this lesson from the Courses tab or import from Files in Dev Mode.")
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
            // Adaptive rate card & simulation
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

                // Unlock status badge
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

            // Transport controls
            HStack(spacing: 24) {
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

                // Play / Pause
                Button {
                    viewModel.togglePlayPause()
                } label: {
                    Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(.white)
                }

                // Step speed manually (-0.05 / +0.05)
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

                // Simulate take result (verifies adaptive speed policy)
                Menu {
                    Button("Simulate Pass Take (Clean)") { viewModel.simulateTake(passed: true) }
                    Button("Simulate Fail Take (Timing/Shape)") { viewModel.simulateTake(passed: false) }
                    Button("Reset Take History") { viewModel.resetHistory() }
                } label: {
                    Image(systemName: "figure.dance")
                        .font(.title3)
                        .foregroundStyle(.cyan)
                }
            }
            .padding(.vertical, 6)
        }
        .padding(.top, 8)
        .padding(.bottom, 20)
        .background(Color.black.opacity(0.8))
    }
}

// MARK: - View Model

@MainActor
public final class LessonPlayerViewModel: ObservableObject {
    @Published public var isPlaying: Bool = false
    @Published public var isCountIn: Bool = false
    @Published public var isMirrored: Bool = true
    @Published public var isLooping: Bool = true
    @Published public var countInBeatsLeft: Int = 4
    @Published public var currentBeatCount: Int = 1
    @Published public var currentPhrase: Int = 1
    @Published public var playbackRate: Double = 0.70
    @Published public var nextSegmentUnlocked: Bool = false
    @Published public var takeHistory: [TakeRecord] = []
    @Published public var statusMessage: String = ""

    public let manifest: LessonManifest
    public let segment: LessonManifest.SegmentInfo
    public let videoURL: URL?
    public let player = AVPlayer()

    private let metronome = Metronome()
    private var timeObserverToken: Any?
    private var countInTask: Task<Void, Never>?
    private var segmentBeats: [LessonManifest.BeatGridInfo.Beat] = []

    public var hasVideo: Bool {
        videoURL != nil && FileManager.default.fileExists(atPath: videoURL!.path)
    }

    public var adaptiveStatusText: String {
        let policy = segment.adaptive_speed ?? manifest.practice.adaptive_speed
        return "Ladder: [\(String(format: "%.1f", policy.min_rate))x - \(String(format: "%.1f", policy.max_rate))x] • Takes: \(takeHistory.count)"
    }

    public init(
        manifest: LessonManifest,
        segment: LessonManifest.SegmentInfo,
        videoURL: URL?
    ) {
        self.manifest = manifest
        self.segment = segment
        self.videoURL = videoURL

        // Mirror flip on by default
        self.isMirrored = manifest.video.default_display_flip

        // Initial rate from policy
        let policy = segment.adaptive_speed ?? manifest.practice.adaptive_speed
        self.playbackRate = policy.start_rate

        // Filter beats belonging to this segment
        self.segmentBeats = manifest.beat_grid.beats.filter {
            $0.t >= (segment.start_s - 0.05) && $0.t <= (segment.end_s + 0.05)
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

    public func restartWithCountIn() {
        guard hasVideo else { return }
        stopPlayback()

        let countInBeats = max(1, manifest.practice.count_in_beats)
        let bpm = manifest.beat_grid.bpm
        let effectiveBPM = bpm * playbackRate
        let beatPeriod = 60.0 / effectiveBPM
        let countInDuration = Double(countInBeats) * beatPeriod

        let clickTimes = (0..<countInBeats).map { Double($0) * beatPeriod }
        let accented: Set<Int> = [0]

        // Seek player to start frame
        player.seek(
            to: CMTime(seconds: segment.start_s, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )

        // Start metronome and capture monotonic host time
        let startHostSeconds: Double
        do {
            startHostSeconds = try metronome.start(
                clickTimes: clickTimes,
                accented: accented,
                duration: countInDuration + 0.1
            )
        } catch {
            print("[LessonPlayer] Metronome error: \(error)")
            // Fallback: direct playback
            player.play()
            player.rate = Float(playbackRate)
            isPlaying = true
            return
        }

        // Host clock alignment: video starts at startHostSeconds + countInDuration
        let videoStartHostSeconds = startHostSeconds + countInDuration
        let videoStartMachTicks = AVAudioTime.hostTime(forSeconds: videoStartHostSeconds)
        let hostClockTime = CMClockMakeHostTimeFromSystemTimeStamp(videoStartMachTicks)

        // Spec §2.4: setRate(rate, time: segment.start_s, atHostTime:)
        player.setRate(
            Float(playbackRate),
            time: CMTime(seconds: segment.start_s, preferredTimescale: 600),
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

    public func setRateManually(_ rate: Double) {
        playbackRate = rate
        if isPlaying {
            player.rate = Float(rate)
        }
        // Manual rate selection moves ladder as per §8 Q6
        let take = TakeRecord(passed: false, rate: rate)
        recordTake(take, updateRateFromPolicy: false)
    }

    // MARK: - Adaptive Speed Policy (Spec §8 Q6 Stub)

    public func simulateTake(passed: Bool) {
        let record = TakeRecord(passed: passed, rate: playbackRate)
        recordTake(record, updateRateFromPolicy: true)
    }

    public func resetHistory() {
        takeHistory.removeAll()
        let policy = segment.adaptive_speed ?? manifest.practice.adaptive_speed
        playbackRate = policy.start_rate
        nextSegmentUnlocked = false
    }

    private func recordTake(_ take: TakeRecord, updateRateFromPolicy: Bool) {
        takeHistory.append(take)
        let policy = segment.adaptive_speed ?? manifest.practice.adaptive_speed
        let (newRate, unlocked) = Self.nextRate(policy: policy, history: takeHistory)
        self.nextSegmentUnlocked = unlocked
        if updateRateFromPolicy {
            self.playbackRate = newRate
            if isPlaying {
                player.rate = Float(newRate)
            }
        }
    }

    /// Pure function mirroring `groove_eval.lesson_package.next_rate`.
    public static func nextRate(
        policy: AdaptiveSpeedPolicy,
        history: [TakeRecord]
    ) -> (rate: Double, unlocked: Bool) {
        let lo = policy.min_rate
        let hi = policy.max_rate
        let up = policy.step_up
        let down = policy.step_down
        let promote = policy.promote_after
        let demote = policy.demote_after
        let unlockAt = policy.unlock_next_at_rate

        func quantize(_ r: Double) -> Double {
            (r * 100.0).rounded() / 100.0
        }
        func clamp(_ r: Double) -> Double {
            min(hi, max(lo, quantize(r)))
        }

        var current = clamp(policy.start_rate)
        var passes = 0
        var fails = 0
        var unlocked = false

        for take in history {
            if let r = take.rate {
                let takenAt = clamp(r)
                if abs(takenAt - current) > 1e-9 {
                    current = takenAt
                    passes = 0
                    fails = 0
                }
            }
            if take.passed {
                passes += 1
                fails = 0
                if current >= (unlockAt - 1e-9) {
                    unlocked = true
                }
            } else {
                passes = 0
                fails += 1
            }

            if passes >= promote {
                current = clamp(current + up)
                passes = 0
            } else if fails >= demote {
                current = clamp(current - down)
                fails = 0
            }
        }

        return (current, unlocked)
    }

    // MARK: - Internal Player Setup & Beat Observer

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
            guard let self else { return }
            let t = CMTimeGetSeconds(time)

            // Loop check
            if t >= self.segment.end_s {
                if self.isLooping {
                    self.player.seek(
                        to: CMTime(seconds: self.segment.start_s, preferredTimescale: 600),
                        toleranceBefore: .zero,
                        toleranceAfter: .zero
                    )
                    self.player.play()
                    self.player.rate = Float(self.playbackRate)
                } else {
                    self.pausePlayback()
                }
                return
            }

            // Update 1..8 beat counter from beat_grid
            if let activeBeat = self.segmentBeats.last(where: { $0.t <= (t + 0.05) }) {
                self.currentBeatCount = activeBeat.count
                self.currentPhrase = activeBeat.phrase
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

// MARK: - Models

public struct TakeRecord: Codable, Identifiable {
    public var id = UUID()
    public var passed: Bool
    public var rate: Double?
    public var timestamp: Date

    public init(passed: Bool, rate: Double? = nil, timestamp: Date = Date()) {
        self.passed = passed
        self.rate = rate
        self.timestamp = timestamp
    }
}
