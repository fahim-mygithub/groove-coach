import XCTest
@testable import GrooveCore

final class MoveSegmenterTests: XCTestCase {

    // Same vectors as tests/test_segmentation.py.
    private func frames(count: Int = 80) -> [GrooveScoringEngine.RawPoseFrame] {
        func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { max(lo, min(hi, v)) }
        return (0..<count).map { i in
            let x = 0.2 * Double(clamp(i, 10, 20) - 10) + 0.3 * Double(clamp(i, 40, 45) - 40)
            return GrooveScoringEngine.RawPoseFrame(
                t: Double(i) / 30.0,
                joints: ["root": [0, 0, 0], "centerShoulder": [0, 2, 0], "rightWrist": [x, 1, 0]]
            )
        }
    }

    func testMotionEnergyIsTorsoNormalised() {
        let e = MoveSegmenter.motionEnergy(frames: frames())
        XCTAssertEqual(e[12], 1.9999999999999996, accuracy: 1e-9)
        XCTAssertEqual(e[25], 0.0, accuracy: 1e-9)
    }

    func testDetectsTwoHits() {
        let hits = MoveSegmenter.detectHits(frames: frames())
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits[0].timestamp, 0.7666666666666667, accuracy: 1e-9)
        XCTAssertEqual(hits[0].peakSpeed, 3.0000000000000013, accuracy: 1e-9)
        XCTAssertEqual(hits[0].settleDuration, 0.1333333333333333, accuracy: 1e-9)
        XCTAssertEqual(hits[1].timestamp, 1.6, accuracy: 1e-9)
        XCTAssertEqual(hits[1].peakSpeed, 4.500000000000008, accuracy: 1e-9)
    }

    func testNoHitWhileStillMoving() {
        XCTAssertTrue(MoveSegmenter.detectHits(frames: frames(count: 18)).isEmpty)
    }

    func testPairsNearestBeatWithinTolerance() {
        let hits = MoveSegmenter.detectHits(frames: frames())
        let pairs = MoveSegmenter.pairHitsToBeats(hits: hits, beats: [0.5, 0.7, 1.0, 1.65])
        XCTAssertEqual(pairs.count, 2)
        XCTAssertEqual(pairs[0].beatTimestamp, 0.7, accuracy: 1e-9)
        XCTAssertEqual(pairs[0].offsetMs, 66.66666666666676, accuracy: 1e-9)
        XCTAssertEqual(pairs[1].beatTimestamp, 1.65, accuracy: 1e-9)
        XCTAssertEqual(pairs[1].offsetMs, -49.99999999999982, accuracy: 1e-9)
    }

    func testBeatOutsideToleranceIsUnmatched() {
        let hits = MoveSegmenter.detectHits(frames: frames())
        XCTAssertTrue(MoveSegmenter.pairHitsToBeats(hits: hits, beats: [0.2, 1.2]).isEmpty)
    }
}
