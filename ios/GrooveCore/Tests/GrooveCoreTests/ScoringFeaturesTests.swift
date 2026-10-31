import XCTest
@testable import GrooveCore

/// Swift mirror of tests/test_scoring_features.py: smoothing, hit timing, joint verdicts, hand styling.
/// Uses the committed fixtures (`fixtures/golden_clips.json`, `fixtures/feature_clips.json`) and config.
final class ScoringFeaturesTests: XCTestCase {

    private struct Dataset: Codable {
        let references: [String: GrooveScoringEngine.PoseClip]
        let golden_clips: [GrooveScoringEngine.PoseClip]
    }

    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // GrooveCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // GrooveCore
        .deletingLastPathComponent() // ios
        .deletingLastPathComponent() // repo root

    private static func load<T: Decodable>(_ type: T.Type, _ relativePath: String) throws -> T {
        let data = try Data(contentsOf: repoRoot.appendingPathComponent(relativePath))
        return try JSONDecoder().decode(type, from: data)
    }

    private var config: GrooveScoringEngine.GrooveConfig!
    private var golden: Dataset!
    private var features: Dataset!

    override func setUpWithError() throws {
        config = try Self.load(GrooveScoringEngine.GrooveConfig.self, "config/groove_config.json")
        golden = try Self.load(Dataset.self, "fixtures/golden_clips.json")
        features = try Self.load(Dataset.self, "fixtures/feature_clips.json")
    }

    private func configWith(
        smoothing: GrooveScoringEngine.SmoothingConfig? = nil,
        hits: GrooveScoringEngine.HitTimingConfig? = nil,
        hands: GrooveScoringEngine.HandStylingThresholds? = nil
    ) -> GrooveScoringEngine.GrooveConfig {
        let t = config.scoring_thresholds
        return GrooveScoringEngine.GrooveConfig(
            version: config.version,
            scoring_thresholds: .init(
                timing: t.timing, shape: t.shape, groove: t.groove, coverage: t.coverage, gate: t.gate,
                smoothing: smoothing ?? t.smoothing,
                hits: hits ?? t.hits,
                joint_tolerance: t.joint_tolerance,
                hands: hands ?? t.hands
            )
        )
    }

    private func goldenClip(_ prefix: String) -> GrooveScoringEngine.PoseClip {
        golden.golden_clips.first { $0.clip_id.hasPrefix(prefix) }!
    }

    private func scoreFeature(_ id: String, _ cfg: GrooveScoringEngine.GrooveConfig? = nil) -> GrooveScoringEngine.AttemptScoreResult {
        let clip = features.golden_clips.first { $0.clip_id == id }!
        return GrooveScoringEngine.scoreAttempt(attempt: clip, reference: features.references["arm_hits"]!, config: cfg ?? config)
    }

    func testConfigDecodesNewSections() {
        let t = config.scoring_thresholds
        XCTAssertEqual(t.smoothing?.enabled, true)
        XCTAssertEqual(t.hits?.beat_tolerance_ms, 150.0)
        XCTAssertEqual(t.joint_tolerance?.position_floor, 0.06)
        XCTAssertEqual(t.hands?.gate, false)
    }

    func testMissingConfigSectionsFallBackToDefaults() throws {
        let json = """
        {"enabled": false}
        """
        let partial = try JSONDecoder().decode(GrooveScoringEngine.HitTimingConfig.self, from: Data(json.utf8))
        XCTAssertFalse(partial.enabled)
        XCTAssertEqual(partial.moving_threshold, 1.0)
        XCTAssertEqual(partial.good_max_ms, 120.0)
    }

    func testSmoothingIsConfigurableAndKeepsGoldenLabels() {
        let ref = golden.references["down_bounce"]!
        let clip = goldenClip("clip_01")
        let on = GrooveScoringEngine.scoreAttempt(attempt: clip, reference: ref, config: config)
        let off = GrooveScoringEngine.scoreAttempt(
            attempt: clip, reference: ref, config: configWith(smoothing: .init(enabled: false))
        )
        XCTAssertTrue(on.smoothing_applied)
        XCTAssertFalse(off.smoothing_applied)
        XCTAssertTrue(on.passed && off.passed)
        for clip in golden.golden_clips {
            let res = GrooveScoringEngine.scoreAttempt(attempt: clip, reference: golden.references[clip.move_tag]!, config: config)
            XCTAssertEqual(res.passed, clip.expected?.passed, clip.clip_id)
        }
    }

    func testSmoothingReducesJitterAndKeepsFrameFields() {
        let frames = (0..<30).map { i in
            GrooveScoringEngine.RawPoseFrame(
                t: Double(i) / 30.0,
                joints: ["root": [0.01 * (i % 2 == 0 ? 1.0 : -1.0), 0.8, 0.0]],
                confidences: ["root": 0.9],
                hands: ["left": [[0.0, 0.0, 0.0]]]
            )
        }
        let smoothed = GrooveScoringEngine.smoothFrames(frames, config: .init())
        XCTAssertEqual(smoothed.map { $0.t }, frames.map { $0.t })
        XCTAssertEqual(smoothed[5].confidences, frames[5].confidences)
        XCTAssertEqual(smoothed[5].hands?["left"]?.count, 1)
        let raw = frames[10...].map { abs($0.joints["root"]![0]) }.max()!
        let smooth = smoothed[10...].map { abs($0.joints["root"]![0]) }.max()!
        XCTAssertLessThan(smooth, 0.5 * raw)
    }

    func testContinuousGroovesHaveNoHitComponent() {
        let res = GrooveScoringEngine.scoreAttempt(attempt: goldenClip("clip_01"), reference: golden.references["down_bounce"]!, config: config)
        XCTAssertEqual(res.hit_timing.status, "not_applicable")
        XCTAssertNil(res.hit_timing.hit_score)
    }

    func testHitTimingOnBeatLateAndMissing() {
        let clean = scoreFeature("feat_01_hits_clean_open_hands").hit_timing
        let late = scoreFeature("feat_02_hits_late_fist_hands").hit_timing
        let missing = scoreFeature("feat_03_no_hits_no_hands").hit_timing
        XCTAssertEqual(clean.status, "available")
        XCTAssertEqual(clean.reference_hit_count, 8)
        XCTAssertEqual(clean.matched_count, 8)
        XCTAssertGreaterThanOrEqual(clean.hit_score ?? 0, 95.0)
        XCTAssertLessThan(abs(clean.mean_offset_ms ?? 999), 40.0)
        XCTAssertEqual(late.matched_count, 8)
        XCTAssertGreaterThan(late.mean_offset_ms ?? 0, 80.0)
        XCTAssertLessThan(late.hit_score ?? 100, 60.0)
        XCTAssertTrue(late.per_hit.allSatisfy { $0.judgment == "Good" || $0.judgment == "Late" })
        XCTAssertEqual(missing.hit_score, 0.0)
        XCTAssertTrue(missing.per_hit.allSatisfy { $0.judgment == "Miss" })
    }

    func testHitGateIsOffByDefaultAndCanFailAttempts() {
        XCTAssertTrue(scoreFeature("feat_02_hits_late_fist_hands").passed)
        var gate = config.scoring_thresholds.hits ?? .init()
        gate.gate = true
        let gated = scoreFeature("feat_02_hits_late_fist_hands", configWith(hits: gate))
        XCTAssertFalse(gated.passed)
        XCTAssertTrue(gated.top_issue.hasPrefix("Hits off the beat"))
    }

    func testJointVerdictsFlagTheWrongJointWithAHint() {
        let clean = scoreFeature("feat_01_hits_clean_open_hands").joint_feedback
        let staticArms = scoreFeature("feat_03_no_hits_no_hands").joint_feedback
        XCTAssertEqual((clean.counts["warn"] ?? 0) + (clean.counts["off"] ?? 0), 0)
        XCTAssertNil(clean.top_hint)
        let flagged = Set(staticArms.verdicts.filter { $0.severity != "ok" }.map { $0.joint })
        XCTAssertTrue(flagged.isSuperset(of: ["leftWrist", "rightWrist"]))
        XCTAssertTrue(["leftWrist", "rightWrist", "leftElbow", "rightElbow"].contains(staticArms.top_joint ?? ""))
        XCTAssertTrue(staticArms.top_hint?.hasPrefix("raise ") ?? false)
    }

    func testJointVerdictsOnGoldenFailures() {
        let ref = golden.references["down_bounce"]!
        let stiff = GrooveScoringEngine.scoreAttempt(attempt: goldenClip("clip_09"), reference: ref, config: config).joint_feedback
        XCTAssertEqual(stiff.top_hint, "bend left knee")
        let clean = GrooveScoringEngine.scoreAttempt(attempt: goldenClip("clip_03"), reference: ref, config: config).joint_feedback
        XCTAssertEqual(clean.counts["ok"], clean.verdicts.count + clean.angle_verdicts.count)
    }

    func testGoldenTakesWidenTolerances() {
        let jt = config.scoring_thresholds.joint_tolerance ?? .init()
        let ref = golden.references["down_bounce"]!
        let alone = GrooveScoringEngine.computeJointTolerances(clips: [ref], beatTimes: ref.beat_times, config: jt)
        let widened = GrooveScoringEngine.computeJointTolerances(clips: [ref, goldenClip("clip_04")], beatTimes: ref.beat_times, config: jt)
        XCTAssertEqual(alone.positions["leftKnee"], jt.position_floor)
        XCTAssertEqual(alone.angles["leftKnee"], jt.angle_floor_deg)
        XCTAssertGreaterThan(widened.angles["leftKnee"] ?? 0, alone.angles["leftKnee"] ?? 0)
    }

    func testHandStylingScoresShapeAndSkipsAbsentHands() {
        let clean = scoreFeature("feat_01_hits_clean_open_hands").hand_styling
        let fist = scoreFeature("feat_02_hits_late_fist_hands").hand_styling
        let absent = scoreFeature("feat_03_no_hits_no_hands").hand_styling
        let mirrored = scoreFeature("feat_04_mirrored_hits_flat_hands").hand_styling
        XCTAssertEqual(clean.status, "available")
        XCTAssertEqual(clean.hand_score ?? 0, 100.0, accuracy: 1e-9)
        XCTAssertEqual(clean.user_shape, "open")
        XCTAssertEqual(fist.user_shape, "fist")
        XCTAssertEqual(fist.reference_shape, "open")
        XCTAssertLessThan(fist.hand_score ?? 100, 50.0)
        XCTAssertEqual(absent.status, "skipped")
        XCTAssertNil(absent.hand_score)
        XCTAssertEqual(mirrored.user_shape, "flat")
        XCTAssertLessThan(mirrored.hand_score ?? 100, clean.hand_score ?? 0)
        XCTAssertGreaterThan(mirrored.hand_score ?? 0, fist.hand_score ?? 100)
    }

    func testAbsentHandsNeverFailAGatedAttempt() {
        let gated = configWith(hands: .init(enabled: true, gate: true, pass_min_score: 60.0))
        XCTAssertTrue(scoreFeature("feat_03_no_hits_no_hands", gated).passed)
        XCTAssertFalse(scoreFeature("feat_02_hits_late_fist_hands", gated).passed)
    }

    // MARK: - Lesson windows, rate stretch, velocity and occlusion (mirror of TestLessonFeatures)

    private func flagged(_ r: GrooveScoringEngine.AttemptScoreResult) -> Set<String> {
        Set((r.joint_feedback.verdicts + r.joint_feedback.angle_verdicts).filter { $0.severity != "ok" }.map { $0.joint })
    }

    private func errors(_ r: GrooveScoringEngine.AttemptScoreResult) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: r.joint_feedback.verdicts.map { ($0.joint, $0.error) })
    }

    func testWindowsComeFromTheManifestSlice() throws {
        let f = try LessonFixtures.get()
        let ref = try XCTUnwrap(f.dataset.references["clasp_windowed"])
        let windows = ref.windows ?? []
        XCTAssertEqual(windows.count, 1)
        let w = try XCTUnwrap(windows.first)
        XCTAssertEqual(w.mask ?? [], ["hand_shape"])
        XCTAssertEqual(w.start_s, ref.beat_times[2] - 0.2, accuracy: 1e-4)
        XCTAssertEqual(GrooveScoringEngine.windowsAt(windows, ref.beat_times[3]).count, 1)
        XCTAssertTrue(GrooveScoringEngine.windowsAt(windows, ref.beat_times[0]).isEmpty)
        XCTAssertTrue(GrooveScoringEngine.windowsAt(windows, w.end_s).isEmpty)
        XCTAssertEqual(f.dataset.references["clasp"]?.windows?.count, 0)
    }

    func testClaspWindowMasksHandsAndScalesWrists() throws {
        let f = try LessonFixtures.get()
        let plain = try f.score("lesson_07_clasp_no_window")
        let windowed = try f.score("lesson_08_clasp_window_mask")
        let near = try f.score("lesson_09_clasp_wrist_proximity")
        XCTAssertTrue(flagged(plain).isSuperset(of: ["leftWrist", "rightWrist"]))
        XCTAssertEqual(plain.hand_styling.masked_samples, 0)
        XCTAssertLessThan(plain.hand_styling.hand_score ?? 100, 80.0)
        XCTAssertEqual(windowed.hand_styling.masked_samples, 12)
        XCTAssertEqual(windowed.hand_styling.hand_score ?? 0, 100.0, accuracy: 1e-9)
        XCTAssertTrue(flagged(windowed).isEmpty)
        XCTAssertEqual(near.hand_styling.masked_samples, 0)
        XCTAssertTrue(flagged(near).isDisjoint(with: ["leftWrist", "rightWrist"]))
    }

    func testRate70Stretch() throws {
        let f = try LessonFixtures.get()
        let ref = try XCTUnwrap(f.dataset.references["hits_rate_70"])
        XCTAssertEqual(ref.speed_pct, 70)
        XCTAssertEqual(ref.bpm, 112.5 * 0.7, accuracy: 1e-9)
        let clean = try f.score("lesson_10_rate70_clean")
        let late = try f.score("lesson_11_rate70_late")
        XCTAssertTrue(clean.passed)
        XCTAssertEqual(clean.hit_timing.status, "available")
        XCTAssertGreaterThanOrEqual(clean.hit_timing.hit_score ?? 0, 95.0)
        XCTAssertFalse(late.passed)
        XCTAssertGreaterThan(late.mean_offset_ms, 120.0)
    }

    func testVelocityFactorsFollowTheReferenceSpeed() throws {
        let f = try LessonFixtures.get()
        let ref = try XCTUnwrap(f.dataset.references["arm_swing"])
        let beat = ref.beat_times[2]
        let g = GrooveScoringEngine.Vec3(0.0, -1.0, 0.0)
        let cfg = GrooveScoringEngine.ToleranceConfig(velocity_scale: 0.5)
        let (pos, ang) = GrooveScoringEngine.referenceVelocityFactors(refFrames: ref.frames, tRef: beat, refGravity: g, config: cfg)
        XCTAssertGreaterThan(pos["leftWrist"] ?? 0, 2.0)
        XCTAssertLessThanOrEqual(pos["leftWrist"] ?? 99, cfg.velocity_max_factor)
        XCTAssertEqual(pos["leftShoulder"] ?? 0, 1.0, accuracy: 0.05)
        XCTAssertNotNil(ang["leftKnee"])
        let capped = GrooveScoringEngine.referenceVelocityFactors(
            refFrames: ref.frames, tRef: beat, refGravity: g, config: .init(velocity_scale: 50.0)
        ).0
        XCTAssertEqual(capped["leftWrist"], cfg.velocity_max_factor)
        let none = GrooveScoringEngine.referenceVelocityFactors(
            refFrames: ref.frames, tRef: beat, refGravity: g, config: .init(velocity_scale: 0.5, velocity_half_window_s: 0.0)
        )
        XCTAssertTrue(none.0.isEmpty && none.1.isEmpty)
    }

    func testVelocityScalingForgivesFastBeats() throws {
        let f = try LessonFixtures.get()
        let off = try f.score("lesson_15_velocity_off")
        let on = try f.score("lesson_16_velocity_scaled")
        XCTAssertTrue(flagged(off).isSuperset(of: ["leftWrist", "rightWrist"]))
        XCTAssertTrue(flagged(on).isEmpty)
        let tolOff = Dictionary(uniqueKeysWithValues: off.joint_feedback.verdicts.map { ($0.joint, $0.tolerance) })
        let tolOn = Dictionary(uniqueKeysWithValues: on.joint_feedback.verdicts.map { ($0.joint, $0.tolerance) })
        XCTAssertEqual(tolOff, tolOn)
    }

    func testOcclusionWidensOrMasksDropouts() throws {
        let f = try LessonFixtures.get()
        let off = try f.score("lesson_17_occlusion_off")
        let widened = try f.score("lesson_18_occlusion_widened")
        let masked = try f.score("lesson_19_occlusion_masked")
        XCTAssertTrue(flagged(off).isSuperset(of: ["leftWrist", "rightWrist"]))
        XCTAssertTrue(flagged(widened).isEmpty)
        XCTAssertTrue(flagged(masked).isEmpty)
        let eOff = errors(off)
        let eWidened = errors(widened)
        let eMasked = errors(masked)
        XCTAssertLessThan(eWidened["leftWrist"] ?? 99, eOff["leftWrist"] ?? 0)
        XCTAssertLessThan(eMasked["leftWrist"] ?? 99, eWidened["leftWrist"] ?? 0)
        XCTAssertEqual(eMasked["leftHip"], eOff["leftHip"])
    }

    func testNewKeysAreNoOpsOnExistingFixtures() throws {
        let data = try LessonFixtures.get().configData
        let neutral = try GrooveScoringEngine.decodeConfig(data, overrides: [LessonFixtures.json(
            #"{"scoring_thresholds": {"tolerance": {"velocity_scale": 0.0, "occlusion": {"factor": 1.0, "mask": false}}, "retarget": {"enabled": false}}}"#
        )])
        let a = scoreFeature("feat_02_hits_late_fist_hands")
        let b = scoreFeature("feat_02_hits_late_fist_hands", neutral)
        XCTAssertEqual(a.shape_score, b.shape_score)
        XCTAssertEqual(a.joint_feedback.counts, b.joint_feedback.counts)
        XCTAssertEqual(a.joint_feedback.verdicts.map { $0.error }, b.joint_feedback.verdicts.map { $0.error })
        XCTAssertEqual(a.hand_styling.hand_score, b.hand_styling.hand_score)
        XCTAssertNil(a.arm_error_deg)
        XCTAssertFalse(a.retargeted)
        XCTAssertEqual(a.timing_source, "bounce")
    }
}

/// fixtures/lesson_clips.json plus each clip's `config_overrides`, deep-merged over config/groove_config.json before
/// decoding like groove-score-cli. Shared by ScoringEngineTests, ScoringFeaturesTests and RetargetTests.
enum LessonFixtures {
    struct Dataset: Codable, Sendable {
        let references: [String: GrooveScoringEngine.PoseClip]
        let golden_clips: [GrooveScoringEngine.PoseClip]
    }

    private struct OverrideItem: Decodable {
        let clip_id: String
        let config_overrides: GrooveScoringEngine.JSONValue?
    }

    private struct Overrides: Decodable {
        let golden_clips: [OverrideItem]
    }

    struct Loaded: Sendable {
        let configData: Data
        let dataset: Dataset
        let overrides: [String: GrooveScoringEngine.JSONValue]

        func clip(_ id: String) -> GrooveScoringEngine.PoseClip {
            dataset.golden_clips.first { $0.clip_id == id }!
        }

        func config(_ id: String) throws -> GrooveScoringEngine.GrooveConfig {
            try GrooveScoringEngine.decodeConfig(configData, overrides: overrides[id].map { [$0] } ?? [])
        }

        func score(_ id: String) throws -> GrooveScoringEngine.AttemptScoreResult {
            let c = clip(id)
            return GrooveScoringEngine.scoreAttempt(attempt: c, reference: dataset.references[c.move_tag]!, config: try config(id))
        }
    }

    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // GrooveCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // GrooveCore
        .deletingLastPathComponent() // ios
        .deletingLastPathComponent() // repo root

    /// Decoded once per test run (the fixture is ~5 MB).
    private static let shared: Result<Loaded, Error> = Result {
        let configData = try Data(contentsOf: repoRoot.appendingPathComponent("config/groove_config.json"))
        let datasetData = try Data(contentsOf: repoRoot.appendingPathComponent("fixtures/lesson_clips.json"))
        let decoder = JSONDecoder()
        let dataset = try decoder.decode(Dataset.self, from: datasetData)
        var overrides: [String: GrooveScoringEngine.JSONValue] = [:]
        for item in try decoder.decode(Overrides.self, from: datasetData).golden_clips {
            if let o = item.config_overrides { overrides[item.clip_id] = o }
        }
        return Loaded(configData: configData, dataset: dataset, overrides: overrides)
    }

    static func get() throws -> Loaded {
        try shared.get()
    }

    static func json(_ text: String) throws -> GrooveScoringEngine.JSONValue {
        try JSONDecoder().decode(GrooveScoringEngine.JSONValue.self, from: Data(text.utf8))
    }
}
