import XCTest
@testable import GrooveCore

/// Tests for the ungraded live matcher: lag convergence, limb states, the beat streak and mirroring.
/// Poses are synthetic: upright body, torso frame equal to the world axes, so bone directions are the inputs.
final class LiveMatcherTests: XCTestCase {

    private typealias Frame = GrooveScoringEngine.RawPoseFrame
    private typealias Vec3 = GrooveScoringEngine.Vec3

    /// Unit directions of each limb in the body frame.
    private struct Directions {
        var leftUpperArm = Vec3(0, -1, 0)
        var leftForearm = Vec3(1, 0, 0)
        var rightUpperArm = Vec3(0, -1, 0)
        var rightForearm = Vec3(0, 0, 1)
        var leftThigh = Vec3(0, -1, 0)
        var leftShin = Vec3(0, -1, 0)
        var rightThigh = Vec3(0, -1, 0)
        var rightShin = Vec3(0, -1, 0)
    }

    private func frame(_ t: Double, _ d: Directions) -> Frame {
        let lShoulder: [Double] = [-0.2, 0.5, 0.0]
        let rShoulder: [Double] = [0.2, 0.5, 0.0]
        let lHip: [Double] = [-0.1, 0.0, 0.0]
        let rHip: [Double] = [0.1, 0.0, 0.0]
        func point(_ p: [Double], _ dir: Vec3, _ length: Double) -> [Double] {
            [p[0] + length * dir.x, p[1] + length * dir.y, p[2] + length * dir.z]
        }
        let lElbow = point(lShoulder, d.leftUpperArm, 0.3)
        let rElbow = point(rShoulder, d.rightUpperArm, 0.3)
        let lKnee = point(lHip, d.leftThigh, 0.45)
        let rKnee = point(rHip, d.rightThigh, 0.45)
        let joints: [String: [Double]] = [
            "root": [0, 0, 0],
            "spine": [0, 0.25, 0],
            "centerShoulder": [0, 0.5, 0],
            "leftHip": lHip,
            "rightHip": rHip,
            "leftShoulder": lShoulder,
            "rightShoulder": rShoulder,
            "leftElbow": lElbow,
            "leftWrist": point(lElbow, d.leftForearm, 0.3),
            "rightElbow": rElbow,
            "rightWrist": point(rElbow, d.rightForearm, 0.3),
            "leftKnee": lKnee,
            "leftAnkle": point(lKnee, d.leftShin, 0.45),
            "rightKnee": rKnee,
            "rightAnkle": point(rKnee, d.rightShin, 0.45)
        ]
        return Frame(t: t, joints: joints)
    }

    /// Camera mirror: x negated and left/right labels swapped, as a selfie camera shows the pose.
    private func mirrored(_ f: Frame) -> Frame {
        var joints: [String: [Double]] = [:]
        for (name, p) in f.joints {
            joints[GrooveScoringEngine.Retarget.mirrorName(name)] = [-p[0], p[1], p[2]]
        }
        return Frame(t: f.t, joints: joints)
    }

    /// Moving reference: the left forearm sweeps in the body's x-y plane, so a lag shows up in the angle errors.
    private func sweep(_ t: Double) -> Directions {
        var d = Directions()
        let phi = 2 * Double.pi * t / 1.3
        d.leftForearm = Vec3(cos(phi), sin(phi), 0)
        return d
    }

    /// Reference frames at 30 fps from -1 s to 8 s, so the lag search never reads before the clip starts.
    private func sweepReference() -> [Frame] {
        (0...270).map { i in
            let t = -1.0 + Double(i) / 30.0
            return frame(t, sweep(t))
        }
    }

    private func assertAllOk(_ state: LiveMatcher.LiveState, file: StaticString = #filePath, line: UInt = #line) {
        for limb in LiveMatcher.Limb.allCases {
            XCTAssertEqual(state.limbs[limb], LiveMatcher.LimbState.ok, "\(limb)", file: file, line: line)
        }
    }

    func testConstantLagConvergesWithinTwoSeconds() {
        let matcher = LiveMatcher(reference: sweepReference(), beatTimes: [])
        // The learner shows the reference 200 ms late: at media time m they perform the pose at m - 0.2.
        for k in 0...60 {
            let m = Double(k) / 30.0
            _ = matcher.update(frame: frame(m, sweep(m - 0.2)), mediaTime: m)
        }
        XCTAssertEqual(matcher.lagSeconds, 0.2, accuracy: 0.02)
    }

    func testWrongArmDirectionTurnsThatLimbOff() {
        // Static reference keeps the lag search still, so this checks the limb state alone.
        let reference = (0...30).map { i in frame(Double(i) / 30.0, Directions()) }
        let matcher = LiveMatcher(reference: reference, beatTimes: [])
        var wrong = Directions()
        wrong.leftForearm = Vec3(0, 0, 1) // 90 degrees from the reference forearm
        let state = matcher.update(frame: frame(0.5, wrong), mediaTime: 0.5)

        XCTAssertEqual(state.limbs[.leftForearm], LiveMatcher.LimbState.off)
        for limb in LiveMatcher.Limb.allCases where limb != .leftForearm {
            XCTAssertEqual(state.limbs[limb], LiveMatcher.LimbState.ok, "\(limb)")
        }
    }

    func testStreakResetsOnMissAndCountsCleanBeats() {
        // Beats every 0.5 s. The learner's left forearm is wrong during beat 1 (1.0 to 1.5 s) only.
        let matcher = LiveMatcher(reference: sweepReference(), beatTimes: (1...8).map { Double($0) * 0.5 })
        var streaks: [Int: Int] = [:]
        for k in 0...150 {
            let m = Double(k) / 30.0
            var d = sweep(m)
            if m >= 1.02 && m < 1.48 {
                d.leftForearm = Vec3(0, 0, 1)
            }
            streaks[k] = matcher.update(frame: frame(m, d), mediaTime: m).streak
        }
        XCTAssertEqual(streaks[40], 1, "beat 0 is clean")
        XCTAssertEqual(streaks[46], 0, "beat 1 had a miss, so the streak resets")
        XCTAssertEqual(streaks[62], 1, "the streak counts again after the miss")
        XCTAssertEqual(streaks[77], 2)
    }

    func testMirroredLearnerMatchesWhenFlagIsSet() {
        var reference = Directions()
        reference.rightForearm = Vec3(0, 0, 1)
        let refFrames = (0...30).map { i in frame(Double(i) / 30.0, reference) }
        let learnerFrame = mirrored(frame(0.5, reference))

        let matched = LiveMatcher(reference: refFrames, beatTimes: [], mirrored: true)
            .update(frame: learnerFrame, mediaTime: 0.5)
        assertAllOk(matched)

        // Without the flag the same mirrored pose is not the reference: the asymmetric forearms disagree.
        let unflagged = LiveMatcher(reference: refFrames, beatTimes: [], mirrored: false)
            .update(frame: learnerFrame, mediaTime: 0.5)
        XCTAssertTrue(unflagged.limbs.values.contains(LiveMatcher.LimbState.off))
    }
}
