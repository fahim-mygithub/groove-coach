import Foundation
import GrooveCore

/// Reference moves, calibration clips and the scoring config shared by the Practice and Calibrate tabs.
/// Persisted to Documents/groove_library.json so imported references survive an app restart.
@MainActor
final class GrooveLibrary: ObservableObject {
    @Published var references: [String: GrooveScoringEngine.PoseClip] = [:] {
        didSet { save() }
    }
    @Published var calibrationClips: [GrooveScoringEngine.PoseClip] = [] {
        didSet { save() }
    }

    /// `config/groove_config.json` bundled as an app resource (same file the Python + Swift parity gate uses).
    let config: GrooveScoringEngine.GrooveConfig

    private var isLoading = false

    private struct LibraryFile: Codable {
        let references: [String: GrooveScoringEngine.PoseClip]
        let calibration_clips: [GrooveScoringEngine.PoseClip]
    }

    private static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("groove_library.json")
    }

    init() {
        config = Self.loadBundledConfig()
        load()
    }

    /// Clean calibration takes of a move; they widen the per-joint tolerances beyond the reference alone.
    func goldenClips(for moveTag: String) -> [GrooveScoringEngine.PoseClip] {
        calibrationClips.filter { $0.move_tag == moveTag && ($0.expected?.passed ?? false) }
    }

    static func loadBundledConfig() -> GrooveScoringEngine.GrooveConfig {
        if let url = Bundle.main.url(forResource: "groove_config", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let config = try? JSONDecoder().decode(GrooveScoringEngine.GrooveConfig.self, from: data) {
            return config
        }
        return fallbackConfig
    }

    /// Used only if the bundled config is missing or unreadable; mirrors config/groove_config.json.
    static let fallbackConfig = GrooveScoringEngine.GrooveConfig(
        version: "1.0.0",
        scoring_thresholds: .init(
            timing: .init(perfect_max_ms: 60.0, good_max_ms: 120.0, search_window_beats: 0.45),
            shape: .init(max_angle_error_deg: 45.0, max_single_joint_error_deg: 24.0, foot_pitch_weight: 0.30, pass_min_score: 70.0),
            groove: .init(min_knee_flex_ratio: 0.65, ideal_spine_lag_ms_min: 30.0, ideal_spine_lag_ms_max: 110.0, max_jerk_ratio: 2.5, pass_min_score: 65.0),
            coverage: .init(min_joint_confidence: 0.50, min_valid_frame_ratio: 0.80),
            gate: .init(min_good_or_better_beat_ratio: 0.80, speed_ladder_pct: [50, 75, 90, 100]),
            smoothing: .init(),
            hits: .init(),
            joint_tolerance: .init(),
            hands: .init()
        )
    )

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let file = try? JSONDecoder().decode(LibraryFile.self, from: data) else { return }
        isLoading = true
        references = file.references
        calibrationClips = file.calibration_clips
        isLoading = false
    }

    private func save() {
        guard !isLoading else { return }
        let file = LibraryFile(references: references, calibration_clips: calibrationClips)
        let url = Self.fileURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(file) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
