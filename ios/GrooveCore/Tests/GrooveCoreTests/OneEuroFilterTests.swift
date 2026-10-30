import XCTest
@testable import GrooveCore

final class OneEuroFilterTests: XCTestCase {

    // Shared with tests/test_one_euro.py: same inputs, same expected outputs.
    static let times = [0.0, 0.033, 0.066, 0.1, 0.1, 0.133, 0.166, 0.2]
    static let inputs = [0.0, 0.5, 0.4, 1.5, 9.0, 1.6, 1.62, 1.58]
    static let expected = [
        0.0, 0.32562549582249173, 0.3737209722701977, 1.322236404352722,
        1.322236404352722, 1.555425022804561, 1.6084372264441136, 1.5858718784763046
    ]

    func testScalarMatchesReferenceVectors() {
        var f = OneEuro.Filter()
        for i in 0..<Self.times.count {
            XCTAssertEqual(f.filter(Self.inputs[i], t: Self.times[i]), Self.expected[i], accuracy: 1e-9)
        }
    }

    func testResetRestartsFromFirstSample() {
        var f = OneEuro.Filter()
        _ = f.filter(5.0, t: 0.0)
        _ = f.filter(6.0, t: 0.1)
        f.reset()
        XCTAssertEqual(f.filter(-3.0, t: 0.0), -3.0, accuracy: 1e-12)
    }

    func testLandmarkBankFiltersEachJointIndependently() {
        var bank = OneEuro.LandmarkBank()
        var scalar = OneEuro.Filter()
        for i in 0..<Self.times.count {
            let out = bank.filter(joints: ["a": [Self.inputs[i], 1.0, 2.0], "b": [0.0, 0.0, 0.0]], t: Self.times[i])
            XCTAssertEqual(out["a"]![0], scalar.filter(Self.inputs[i], t: Self.times[i]), accuracy: 1e-12)
            XCTAssertEqual(out["a"]![1], 1.0, accuracy: 1e-12)
            XCTAssertEqual(out["b"]![2], 0.0, accuracy: 1e-12)
        }
    }

    func testFrameOverloadKeepsTimestampAndConfidences() {
        var bank = OneEuro.LandmarkBank()
        let frame = GrooveScoringEngine.RawPoseFrame(t: 1.0, joints: ["j": [1.0, 2.0, 3.0]], confidences: ["j": 0.9])
        let out = bank.filter(frame)
        XCTAssertEqual(out.t, 1.0)
        XCTAssertEqual(out.joints["j"]!, [1.0, 2.0, 3.0])
        XCTAssertEqual(out.confidences?["j"], 0.9)
    }
}
