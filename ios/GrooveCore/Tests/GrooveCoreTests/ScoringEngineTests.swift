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
}
