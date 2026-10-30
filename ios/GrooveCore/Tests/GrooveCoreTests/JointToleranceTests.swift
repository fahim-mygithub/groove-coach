import XCTest
@testable import GrooveCore

final class JointToleranceTests: XCTestCase {
    typealias JT = JointTolerance

    private func frame(_ j: [String: [Double]]) -> JT.RawFrame { JT.RawFrame(joints: j) }

    // Vectors below are shared with tests/test_joint_tolerance.py (same inputs, same expected values).
    func testPositionTolerancesFromVariance() {
        let refs = [
            frame(["leftWrist": [0, 0, 0], "root": [0, 0, 0], "spine": [0, 0, 0]]),
            frame(["leftWrist": [0.1, 0, 0], "root": [0, 0, 0], "spine": [2, 0, 0]])
        ]
        let tol = JT.positionTolerances(references: refs)
        XCTAssertEqual(tol["leftWrist"]!, 0.1, accuracy: 1e-9)   // 2 * 0.05
        XCTAssertEqual(tol["root"]!, 0.03, accuracy: 1e-9)       // floor
        XCTAssertEqual(tol["spine"]!, 0.25, accuracy: 1e-9)      // ceiling
    }

    func testVerdictsAndHints() {
        let ref = frame(["leftWrist": [0, 1, 0], "rightWrist": [0, 1, 0], "root": [0, 0, 0], "leftAnkle": [0, 0, 0]])
        let learner = frame(["leftWrist": [0, 0.95, 0], "rightWrist": [0, 0.85, 0], "root": [0, 0, 0], "leftAnkle": [0.5, 0, 0]])
        let tols = ["leftWrist": 0.1, "rightWrist": 0.1, "root": 0.1, "leftAnkle": 0.1]
        let v = JT.evaluate(learner: learner, reference: ref, tolerances: tols)
        let by = Dictionary(uniqueKeysWithValues: v.map { ($0.joint, $0) })
        XCTAssertEqual(by["leftWrist"]!.severity, .ok)
        XCTAssertNil(by["leftWrist"]!.hint)
        XCTAssertEqual(by["leftWrist"]!.error, 0.05, accuracy: 1e-9)
        XCTAssertEqual(by["rightWrist"]!.severity, .warn)
        XCTAssertEqual(by["rightWrist"]!.hint, "raise right wrist")
        XCTAssertEqual(by["rightWrist"]!.direction.y, 1.0, accuracy: 1e-9)
        XCTAssertEqual(by["leftAnkle"]!.severity, .off)
        XCTAssertEqual(by["leftAnkle"]!.hint, "move left ankle left")
        XCTAssertEqual(v.map { $0.joint }, ["leftAnkle", "leftWrist", "rightWrist", "root"])
    }

    func testAngleToleranceAndVerdict() {
        // Knee at origin; hip straight above; ankle straight below (180 deg) vs perpendicular (90 deg).
        let straight = frame(["leftHip": [0, 1, 0], "leftKnee": [0, 0, 0], "leftAnkle": [0, -1, 0]])
        let bent = frame(["leftHip": [0, 1, 0], "leftKnee": [0, 0, 0], "leftAnkle": [1, 0, 0]])
        let tol = JT.angleTolerances(references: [straight, bent])
        XCTAssertEqual(tol["leftKnee"]!, 45.0, accuracy: 1e-9)  // 2 * 45 = 90 -> ceiling 45
        let v = JT.evaluateAngles(learner: bent, reference: straight, tolerances: ["leftKnee": 10.0])
        XCTAssertEqual(v.count, 1)
        XCTAssertEqual(v[0].error, 90.0, accuracy: 1e-9)
        XCTAssertEqual(v[0].severity, .off)
        XCTAssertEqual(v[0].hint, "open left knee")
    }
}
