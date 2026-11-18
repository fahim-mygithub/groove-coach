import XCTest
@testable import GrooveCore

/// Swift mirror of tests/test_retarget.py: bone-length retargeting and its wiring into scoreAttempt.
final class RetargetTests: XCTestCase {

    typealias Engine = GrooveScoringEngine
    typealias Retarget = GrooveScoringEngine.Retarget

    /// A small canonical frame: root at origin, arms out to the sides (same as `_frame` in tests/test_retarget.py).
    private func frame(scale: Double = 1.0, arm: Double = 1.0) -> Engine.RawPoseFrame {
        let joints: [String: [Double]] = [
            "root": [0.0, 0.0, 0.0],
            "spine": [0.0, 0.25 * scale, 0.0],
            "centerShoulder": [0.0, 0.5 * scale, 0.0],
            "leftShoulder": [-0.18 * scale, 0.5 * scale, 0.0],
            "leftElbow": [-(0.18 * scale + 0.28 * arm), 0.5 * scale, 0.0],
            "leftWrist": [-(0.18 * scale + 0.54 * arm), 0.5 * scale + 0.0, 0.0],
            "rightShoulder": [0.18 * scale, 0.5 * scale, 0.0],
            "rightElbow": [0.18 * scale + 0.28 * arm * 0.6, 0.5 * scale + 0.28 * arm * 0.8, 0.0],
            "rightWrist": [0.18 * scale + 0.28 * arm * 0.6, 0.5 * scale + 0.28 * arm * 0.8 + 0.26 * arm, 0.0],
            "leftHip": [-0.11 * scale, 0.0, 0.0],
            "leftKnee": [-0.11 * scale, -0.42 * scale, 0.05 * scale],
            "leftAnkle": [-0.11 * scale, -0.82 * scale, 0.0],
            "rightHip": [0.11 * scale, 0.0, 0.0],
            "rightKnee": [0.11 * scale, -0.42 * scale, 0.05 * scale],
            "rightAnkle": [0.11 * scale, -0.82 * scale, 0.0]
        ]
        return Engine.RawPoseFrame(t: 0.0, joints: joints, confidences: joints.mapValues { _ in 0.9 })
    }

    private func clip(_ frames: [Engine.RawPoseFrame], mirrored: Bool = false, calibration: [Engine.RawPoseFrame]? = nil) -> Engine.PoseClip {
        Engine.PoseClip(clip_id: "c", move_tag: "m", bpm: 112.5, beat_times: [0.5], mirrored: mirrored, frames: frames,
                        calibration_frames: calibration)
    }

    private func dist(_ a: [Double], _ b: [Double]) -> Double {
        Engine.Retarget.length(Engine.Vec3(array: a), Engine.Vec3(array: b))
    }

    private func unit(_ a: [Double], _ b: [Double]) -> Engine.Vec3 {
        Engine.Vec3(b[0] - a[0], b[1] - a[1], b[2] - a[2]).normalized
    }

    func testMirrorName() {
        XCTAssertEqual(Retarget.mirrorName("leftWrist"), "rightWrist")
        XCTAssertEqual(Retarget.mirrorName("rightFootIndex"), "leftFootIndex")
        XCTAssertEqual(Retarget.mirrorName("spine"), "spine")
    }

    func testMedianBoneLengths() {
        let lengths = Retarget.medianBoneLengths([frame(scale: 1.0), frame(scale: 1.2), frame(scale: 1.1)])
        XCTAssertEqual(lengths["spine"] ?? 0, 0.25 * 1.1, accuracy: 1e-12)
        let even = Retarget.medianBoneLengths([frame(scale: 1.0), frame(scale: 1.2)])
        XCTAssertEqual(even["spine"] ?? 0, 0.25 * 1.1, accuracy: 1e-12)
        XCTAssertNil(lengths["nose"])
    }

    func testRetargetKeepsDirectionsAndTakesLearnerLengths() throws {
        let teacher = frame(scale: 1.0, arm: 1.0)
        let learnerLengths = Retarget.medianBoneLengths([frame(scale: 1.15, arm: 1.4)])
        let out = Retarget.retargetFrame(teacher, lengths: learnerLengths)
        XCTAssertEqual(out.joints["root"], [0.0, 0.0, 0.0])
        for bone in Retarget.canonicalBones {
            guard let want = learnerLengths[bone.child] else { continue }
            let c = try XCTUnwrap(out.joints[bone.child])
            let p = try XCTUnwrap(out.joints[bone.parent])
            XCTAssertEqual(dist(c, p), want, accuracy: 1e-12, bone.child)
            let u0 = unit(teacher.joints[bone.parent]!, teacher.joints[bone.child]!)
            let u1 = unit(p, c)
            XCTAssertEqual(u0.x, u1.x, accuracy: 1e-12, bone.child)
            XCTAssertEqual(u0.y, u1.y, accuracy: 1e-12, bone.child)
            XCTAssertEqual(u0.z, u1.z, accuracy: 1e-12, bone.child)
        }
        XCTAssertEqual(out.confidences, teacher.confidences)
    }

    func testMissingLengthsKeepTeacherBonesAndHandsFollowTheWrist() throws {
        var joints = frame().joints
        joints["nose"] = [0.0, 0.7, 0.05]
        let wrist = joints["leftWrist"]!
        let hand = (0..<21).map { i in [wrist[0] + 0.01 * Double(i), wrist[1], wrist[2]] }
        let teacher = Engine.RawPoseFrame(t: 0.0, joints: joints, hands: ["left": hand])
        let out = Retarget.retargetFrame(teacher, lengths: ["leftElbow": 0.5, "leftWrist": 0.5])
        XCTAssertEqual(out.joints["nose"], joints["nose"])
        XCTAssertEqual(dist(out.joints["leftShoulder"]!, out.joints["leftElbow"]!), 0.5, accuracy: 1e-12)
        let newWrist = try XCTUnwrap(out.joints["leftWrist"])
        let moved = try XCTUnwrap(out.hands?["left"])
        for (got, was) in zip(moved, hand) {
            for k in 0..<3 {
                XCTAssertEqual(got[k], was[k] + (newWrist[k] - wrist[k]), accuracy: 1e-12)
            }
        }
        XCTAssertEqual(moved[0], newWrist)
    }

    func testLearnerLengthsPreferCalibrationAndSwapWhenMirrored() {
        let take = clip([frame(scale: 1.0)])
        XCTAssertEqual(Retarget.learnerBoneLengths(attempt: take)["spine"] ?? 0, 0.25, accuracy: 1e-12)
        let calibrated = clip([frame(scale: 1.0)], calibration: [frame(scale: 1.3)])
        XCTAssertEqual(Retarget.learnerBoneLengths(attempt: calibrated)["spine"] ?? 0, 0.325, accuracy: 1e-12)
        let emptyStance = clip([frame(scale: 1.0)], calibration: [])
        XCTAssertEqual(Retarget.learnerBoneLengths(attempt: emptyStance)["spine"], 0.25)
        let plain = Retarget.learnerBoneLengths(attempt: take)
        let mirrored = Retarget.learnerBoneLengths(attempt: clip([frame(scale: 1.0)], mirrored: true))
        XCTAssertEqual(mirrored["leftElbow"], plain["rightElbow"])
        XCTAssertEqual(mirrored["rightWrist"], plain["leftWrist"])
        XCTAssertEqual(mirrored["spine"], plain["spine"])
    }

    func testFrameWithoutRootIsUnchanged() {
        let f = Engine.RawPoseFrame(t: 0.0, joints: ["leftHip": [0.1, 0.0, 0.0]])
        XCTAssertEqual(Retarget.retargetFrame(f, lengths: ["leftHip": 1.0]).joints, f.joints)
    }

    func testLongArmedLearnerNeedsRetarget() throws {
        let f = try LessonFixtures.get()
        let off = try f.score("lesson_12_retarget_off")
        let on = try f.score("lesson_13_retarget_on")
        let calibrated = try f.score("lesson_14_retarget_calibration")
        XCTAssertFalse(off.retargeted)
        XCTAssertTrue(on.retargeted && calibrated.retargeted)
        let flagged = Set(off.joint_feedback.verdicts.filter { $0.severity != "ok" }.map { $0.joint })
        XCTAssertTrue(flagged.isSuperset(of: ["leftWrist", "rightWrist"]))
        XCTAssertTrue(off.joint_feedback.top_hint?.hasPrefix("move ") ?? false)
        for res in [on, calibrated] {
            XCTAssertEqual((res.joint_feedback.counts["warn"] ?? 0) + (res.joint_feedback.counts["off"] ?? 0), 0)
        }
        // Angles are invariant to bone lengths: the shape score passes either way.
        XCTAssertTrue(off.passed && on.passed && calibrated.passed)
        XCTAssertLessThan(abs(off.shape_score - on.shape_score), 1.0)
        XCTAssertNotNil(f.clip("lesson_14_retarget_calibration").calibration_frames)
    }
}
