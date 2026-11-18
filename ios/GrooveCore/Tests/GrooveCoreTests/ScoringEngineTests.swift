import XCTest
@testable import GrooveCore

final class ScoringEngineTests: XCTestCase {

    func testGravityCorrectionRotatesTiltedCameraToVertical() {
        let deg = 22.0
        let rad = deg * .pi / 180.0
        let c = cos(rad)
        let s = sin(rad)

        // Point at (0, 1, 0) rotated by 22 deg around X axis, along with gravity (0, -1, 0) rotated by 22 deg
        let tiltedPoint = GrooveScoringEngine.Vec3(0.0, c, s)
        let tiltedGravity = GrooveScoringEngine.Vec3(0.0, -c, -s)

        let corrected = GrooveScoringEngine.applyGravityCorrection(
            point: tiltedPoint,
            gravityVector: tiltedGravity
        )

        XCTAssertEqual(corrected.x, 0.0, accuracy: 1e-6)
        XCTAssertEqual(corrected.y, 1.0, accuracy: 1e-6)
        XCTAssertEqual(corrected.z, 0.0, accuracy: 1e-6)
    }

    func testParabolicPeakInterpolation() {
        // Symmetric parabola peaking at t = 0.50
        let peak = GrooveScoringEngine.parabolicPeakTime(
            t0: 0.45, y0: 10.0,
            t1: 0.50, y1: 20.0,
            t2: 0.55, y2: 10.0
        )
        XCTAssertEqual(peak, 0.50, accuracy: 1e-6)
    }

    func testVerifyClapSyncHostTimeAlignment() {
        let frameTimes = [10.000, 10.0167, 10.0333, 10.0500, 10.0667]
        let wristDists = [0.35, 0.14, 0.02, 0.15, 0.36]
        let ok = GrooveScoringEngine.verifyClapSync(
            wristDistances: wristDists,
            frameHostTimes: frameTimes,
            audioOnsetHostTime: 10.0360,
            maxToleranceMs: 30.0
        )
        XCTAssertTrue(ok.synced)
        XCTAssertLessThanOrEqual(abs(ok.offset_ms), 10.0)

        let bad = GrooveScoringEngine.verifyClapSync(
            wristDistances: wristDists,
            frameHostTimes: frameTimes,
            audioOnsetHostTime: 10.1200,
            maxToleranceMs: 30.0
        )
        XCTAssertFalse(bad.synced)
        XCTAssertGreaterThan(abs(bad.offset_ms), 70.0)
    }

    func testMissingFootJointsReportZeroFootCoverage() {
        let bodyOnlyFrame = GrooveScoringEngine.RawPoseFrame(
            t: 0.0,
            joints: [
                "root": [0.0, 0.90, 2.2],
                "spine": [0.0, 1.15, 2.2],
                "centerShoulder": [0.0, 1.42, 2.2],
                "leftHip": [-0.11, 0.90, 2.2],
                "leftKnee": [-0.12, 0.50, 2.15],
                "leftAnkle": [-0.12, 0.08, 2.2],
                "rightHip": [0.11, 0.90, 2.2],
                "rightKnee": [0.12, 0.50, 2.15],
                "rightAnkle": [0.12, 0.08, 2.2],
                "leftShoulder": [-0.19, 1.40, 2.2],
                "rightShoulder": [0.19, 1.40, 2.2]
            ],
            confidences: [
                "root": 0.95, "spine": 0.95, "centerShoulder": 0.95,
                "leftHip": 0.95, "leftKnee": 0.95, "leftAnkle": 0.95,
                "rightHip": 0.95, "rightKnee": 0.95, "rightAnkle": 0.95,
                "leftShoulder": 0.95, "rightShoulder": 0.95,
                "leftHeel": 0.0, "leftFootIndex": 0.0,
                "rightHeel": 0.0, "rightFootIndex": 0.0
            ]
        )
        let footCov = GrooveScoringEngine.scoreFootCoverage(frames: [bodyOnlyFrame], minConfidence: 0.5)
        let totalCov = GrooveScoringEngine.scoreCoverage(frames: [bodyOnlyFrame], minConfidence: 0.5)
        XCTAssertEqual(footCov, 0.0, accuracy: 1e-6)
        XCTAssertEqual(totalCov, 0.0, accuracy: 1e-6)
    }

    // MARK: - Config overrides and the spec 3.2 keys (mirror of TestLessonScoringKeys in tests/test_scoring.py)

    func testDeepMergeReplacesLeavesAndMergesObjects() throws {
        let base = try LessonFixtures.json(#"{"a": {"b": 1, "c": {"d": 2}}, "e": [1, 2], "f": 3}"#)
        let override = try LessonFixtures.json(#"{"a": {"c": {"d": 5, "g": 6}}, "e": [9], "f": {"h": 1}}"#)
        let want = try LessonFixtures.json(#"{"a": {"b": 1, "c": {"d": 5, "g": 6}}, "e": [9], "f": {"h": 1}}"#)
        XCTAssertEqual(GrooveScoringEngine.deepMerge(base, override), want)
        XCTAssertEqual(try LessonFixtures.json(#"[true, 0.45, 50, "x", null]"#),
                       .array([.bool(true), .double(0.45), .int(50), .string("x"), .null]))
    }

    func testDecodeConfigMergesOverridesBeforeDecoding() throws {
        let data = try LessonFixtures.get().configData
        let plain = try GrooveScoringEngine.decodeConfig(data).scoring_thresholds
        XCTAssertEqual(plain.shape.arm_weight, 0.0)
        XCTAssertEqual(plain.gate.timing_source, "bounce")
        XCTAssertEqual(plain.retarget?.enabled, false)
        XCTAssertEqual(plain.tolerance?.velocity_scale, 0.0)
        XCTAssertEqual(plain.tolerance?.velocity_max_factor, 3.0)
        XCTAssertEqual(plain.tolerance?.occlusion.factor, 1.0)
        XCTAssertEqual(plain.tolerance?.occlusion.mask, false)

        let lesson = try LessonFixtures.json(#"{"scoring_thresholds": {"shape": {"arm_weight": 0.35}, "groove": {"pass_min_score": 0}}}"#)
        let segment = try LessonFixtures.json(
            #"{"scoring_thresholds": {"gate": {"timing_source": "hits"}, "shape": {"arm_weight": 0.5}, "tolerance": {"occlusion": {"factor": 2.5}}}}"#
        )
        let t = try GrooveScoringEngine.decodeConfig(data, overrides: [lesson, segment]).scoring_thresholds
        XCTAssertEqual(t.shape.arm_weight, 0.5)
        XCTAssertEqual(t.shape.pass_min_score, 70.0)
        XCTAssertEqual(t.groove.pass_min_score, 0.0)
        XCTAssertEqual(t.groove.min_knee_flex_ratio, 0.65)
        XCTAssertEqual(t.gate.timing_source, "hits")
        XCTAssertEqual(t.gate.speed_ladder_pct, [50, 75, 90, 100])
        XCTAssertEqual(t.tolerance?.occlusion.factor, 2.5)
        XCTAssertEqual(t.tolerance?.occlusion.min_confidence, 0.5)
        XCTAssertEqual(t.hits?.window_s, 0.110)
    }

    func testTorsoFrameCancelsYaw() throws {
        let pose: [String: [Double]] = [
            "leftHip": [-0.1, 0.0, 0.0], "rightHip": [0.1, 0.0, 0.0], "centerShoulder": [0.0, 0.5, 0.0],
            "leftShoulder": [-0.18, 0.5, 0.0], "leftElbow": [-0.46, 0.5, 0.0], "leftWrist": [-0.46, 0.76, 0.0]
        ]
        let c = cos(0.7)
        let s = sin(0.7)
        let yawed = pose.mapValues { v in [v[0] * c + v[2] * s, v[1], -v[0] * s + v[2] * c] }
        let a = try XCTUnwrap(GrooveScoringEngine.torsoFrameArmVectors(pose))
        let b = try XCTUnwrap(GrooveScoringEngine.torsoFrameArmVectors(yawed))
        XCTAssertEqual(a.keys.sorted(), ["leftForearm", "leftUpperArm"])
        for (bone, v) in a {
            let w = try XCTUnwrap(b[bone])
            XCTAssertEqual(v.x, w.x, accuracy: 1e-12)
            XCTAssertEqual(v.y, w.y, accuracy: 1e-12)
            XCTAssertEqual(v.z, w.z, accuracy: 1e-12)
        }
        let degenerate: [String: [Double]] = ["leftHip": [0, 0, 0], "rightHip": [0, 0, 0], "centerShoulder": [0, 1, 0]]
        XCTAssertNil(GrooveScoringEngine.torsoFrameArmVectors(degenerate))
    }

    func testLessonClipsMatchExpectedLabels() throws {
        let f = try LessonFixtures.get()
        for clip in f.dataset.golden_clips {
            XCTAssertEqual(try f.score(clip.clip_id).passed, clip.expected?.passed, clip.clip_id)
        }
    }

    func testWrongArmDirectionSameElbowAngle() throws {
        let f = try LessonFixtures.get()
        let flat = try f.score("lesson_01_arm_gather_unweighted")
        let weighted = try f.score("lesson_02_arm_gather_weighted")
        let right = try f.score("lesson_03_arm_ear_flick_weighted")
        XCTAssertTrue(flat.passed)
        XCTAssertNil(flat.arm_error_deg)
        XCTAssertFalse(weighted.passed)
        XCTAssertGreaterThan(weighted.arm_error_deg ?? 0, 45.0)
        XCTAssertEqual(weighted.worst_joints.first?.joint, "arms")
        XCTAssertTrue(weighted.top_issue.hasPrefix("Shape error on arms"))
        XCTAssertTrue(right.passed)
        XCTAssertLessThan(right.arm_error_deg ?? 99, 5.0)
        XCTAssertGreaterThanOrEqual(right.shape_score, 95.0)
    }

    func testArmOnlyHitsTimingSource() throws {
        let f = try LessonFixtures.get()
        let bounce = try f.score("lesson_04_arm_only_bounce_gate")
        let hits = try f.score("lesson_05_arm_only_hits_gate")
        let late = try f.score("lesson_06_arm_only_hits_late")
        XCTAssertEqual(bounce.good_or_better_ratio, 0.0)
        XCTAssertFalse(bounce.passed)
        XCTAssertEqual(bounce.timing_source, "bounce")
        XCTAssertFalse(bounce.timing_passed)
        XCTAssertTrue(hits.passed)
        XCTAssertEqual(hits.timing_source, "hits")
        XCTAssertTrue(hits.timing_passed)
        XCTAssertEqual(hits.hit_timing.on_beat_ratio, 1.0)
        XCTAssertTrue(hits.top_issue.hasSuffix("of accents on the beat."))
        XCTAssertFalse(late.passed)
        XCTAssertFalse(late.timing_passed)
        XCTAssertTrue(late.top_issue.hasPrefix("Hit timing off"))
    }
}
