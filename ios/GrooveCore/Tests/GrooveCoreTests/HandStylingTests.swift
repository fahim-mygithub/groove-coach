import XCTest
@testable import GrooveCore

final class HandStylingTests: XCTestCase {

    typealias Vec3 = GrooveScoringEngine.Vec3

    // Shared verbatim with tests/test_hand_styling.py to pin Swift/Python parity.
    private static let fixtures: [(name: String, isLeft: Bool, points: [[Double]], label: String, orientation: String,
                                   curls: [Double], gaps: [Double], thumbExtension: Double, normal: [Double],
                                   confidence: Double, scoreVsOpen: Double)] = [
        (
            name: "open", isLeft: false,
            points: [
                [0.0, 0.0, 0.0],
                [0.2, 0.2, 0.0],
                [0.4298, 0.3928, 0.0],
                [0.6596, 0.5857, 0.0],
                [0.8511, 0.7464, 0.0],
                [0.3, 0.95, 0.0],
                [0.525, 1.3397, 0.0],
                [0.65, 1.5562, 0.0],
                [0.75, 1.7294, 0.0],
                [0.05, 1.0, 0.0],
                [0.1368, 1.4924, 0.0],
                [0.1854, 1.7682, 0.0],
                [0.2236, 1.9848, 0.0],
                [-0.2, 0.93, 0.0],
                [-0.2799, 1.383, 0.0],
                [-0.325, 1.6391, 0.0],
                [-0.3598, 1.836, 0.0],
                [-0.4, 0.8, 0.0],
                [-0.58, 1.1118, 0.0],
                [-0.68, 1.285, 0.0],
                [-0.765, 1.4322, 0.0],
            ],
            label: "open", orientation: "camera",
            curls: [1.9401110717964798e-08, 0.0, 4.190963872237793e-09, 7.799925668313298e-08, 3.5671624913173145e-09],
            gaps: [0.9869523911739059, 0.584356431386481, 0.6013260492082138, 0.5713365177011294],
            thumbExtension: 0.5867737310678808,
            normal: [0.0, -0.0, 1.0],
            confidence: 0.986401250306093, scoreVsOpen: 100.0
        ),
        (
            name: "flat", isLeft: false,
            points: [
                [0.0, 0.0, 0.0],
                [0.2, 0.2, 0.0],
                [0.2521, 0.4954, 0.0],
                [0.3042, 0.7909, 0.0],
                [0.3476, 1.0371, 0.0],
                [0.3, 0.95, 0.0],
                [0.3, 1.4, 0.0],
                [0.3, 1.65, 0.0],
                [0.3, 1.85, 0.0],
                [0.05, 1.0, 0.0],
                [0.05, 1.5, 0.0],
                [0.05, 1.78, 0.0],
                [0.05, 2.0, 0.0],
                [-0.2, 0.93, 0.0],
                [-0.2, 1.39, 0.0],
                [-0.2, 1.65, 0.0],
                [-0.2, 1.85, 0.0],
                [-0.4, 0.8, 0.0],
                [-0.4, 1.16, 0.0],
                [-0.4, 1.36, 0.0],
                [-0.4, 1.53, 0.0],
            ],
            label: "flat", orientation: "camera",
            curls: [2.2256163578759924e-09, 0.0, 0.0, 0.0, 0.0],
            gaps: [0.8132764741718506, 0.2911838421430472, 0.2911838421430472, 0.3768884288228395],
            thumbExtension: 0.09913425743660065,
            normal: [0.0, -0.0, 1.0],
            confidence: 0.9519358199548067, scoreVsOpen: 85.40921621246898
        ),
        (
            name: "fist", isLeft: false,
            points: [
                [0.0, 0.0, 0.0],
                [0.2, 0.2, 0.0],
                [0.1036, 0.4649, -0.1026],
                [0.0523, 0.6059, -0.3624],
                [0.0815, 0.5255, -0.5973],
                [0.3, 0.95, 0.0],
                [0.3, 0.95, -0.45],
                [0.3, 0.7038, -0.4066],
                [0.3, 0.6691, -0.2096],
                [0.05, 1.0, 0.0],
                [0.05, 1.0, -0.5],
                [0.05, 0.7243, -0.4514],
                [0.05, 0.6861, -0.2347],
                [-0.2, 0.93, 0.0],
                [-0.2, 0.93, -0.46],
                [-0.2, 0.6739, -0.4149],
                [-0.2, 0.6392, -0.2179],
                [-0.4, 0.8, 0.0],
                [-0.4, 0.8, -0.36],
                [-0.4, 0.603, -0.3253],
                [-0.4, 0.5735, -0.1579],
            ],
            label: "fist", orientation: "camera",
            curls: [0.6255460661008857, 1.0, 1.0, 1.0, 1.0],
            gaps: [0.4670430141404073, 0.2515171124503492, 0.2545973301092396, 0.21862524443950754],
            thumbExtension: 0.7637091467619597,
            normal: [0.0, -0.0, 1.0],
            confidence: 0.9714730648089598, scoreVsOpen: 36.45329935033303
        ),
        (
            name: "cupped", isLeft: false,
            points: [
                [0.0, 0.0, 0.0],
                [0.2, 0.2, 0.0],
                [0.3683, 0.4404, -0.0624],
                [0.5075, 0.6392, -0.2387],
                [0.5658, 0.7225, -0.4671],
                [0.3, 0.95, 0.0],
                [0.3443, 1.2651, -0.3182],
                [0.3413, 1.2435, -0.5672],
                [0.3234, 1.1162, -0.7205],
                [0.05, 1.0, 0.0],
                [0.0664, 1.3532, -0.3536],
                [0.0653, 1.3288, -0.6325],
                [0.0587, 1.1875, -0.801],
                [-0.2, 0.93, 0.0],
                [-0.2151, 1.2549, -0.3253],
                [-0.2141, 1.2323, -0.5843],
                [-0.2081, 1.1039, -0.7375],
                [-0.4, 0.8, 0.0],
                [-0.4354, 1.0521, -0.2546],
                [-0.433, 1.0348, -0.4538],
                [-0.4178, 0.9266, -0.584],
            ],
            label: "cupped", orientation: "camera",
            curls: [0.23303971964302378, 0.593433344795243, 0.5910679116667535, 0.5877263947542929, 0.6034260999188161],
            gaps: [0.5265698628376655, 0.28535322644119343, 0.2863537215845756, 0.31420505717622094],
            thumbExtension: 0.582871300218542,
            normal: [0.0, -0.0, 1.0],
            confidence: 0.9718362794371227, scoreVsOpen: 60.55914682100951
        ),
        (
            name: "point", isLeft: false,
            points: [
                [0.0, 0.0, 0.0],
                [0.2, 0.2, 0.0],
                [0.151, 0.4776, -0.1026],
                [0.125, 0.6253, -0.3624],
                [0.1398, 0.5411, -0.5973],
                [0.3, 0.95, 0.0],
                [0.3392, 1.3983, 0.0],
                [0.361, 1.6473, 0.0],
                [0.3784, 1.8466, 0.0],
                [0.05, 1.0, 0.0],
                [0.05, 1.0, -0.5],
                [0.042, 0.7244, -0.4514],
                [0.0409, 0.6862, -0.2347],
                [-0.2, 0.93, 0.0],
                [-0.2, 0.93, -0.46],
                [-0.1926, 0.6741, -0.4149],
                [-0.1915, 0.6393, -0.2179],
                [-0.4, 0.8, 0.0],
                [-0.4, 0.8, -0.36],
                [-0.3828, 0.6038, -0.3253],
                [-0.3803, 0.5744, -0.1579],
            ],
            label: "point", orientation: "camera",
            curls: [0.6254236274646956, 1.2128219539775387e-08, 1.0, 1.0, 1.0],
            gaps: [1.4535286842406052, 1.2295280200628615, 0.2373830936842013, 0.2082044123133157],
            thumbExtension: 0.7404457375623916,
            normal: [0.0, -0.0, 1.0],
            confidence: 0.9731450240212023, scoreVsOpen: 43.82081516416162
        ),
        (
            name: "soft", isLeft: false,
            points: [
                [0.0, 0.0, 0.0],
                [0.2, 0.2, 0.0],
                [0.3711, 0.4444, -0.0314],
                [0.5348, 0.6781, -0.1241],
                [0.655, 0.8499, -0.2602],
                [0.3, 0.95, 0.0],
                [0.3864, 1.3567, -0.1722],
                [0.4216, 1.5219, -0.3565],
                [0.4391, 1.6045, -0.5378],
                [0.05, 1.0, 0.0],
                [0.0822, 1.4608, -0.1913],
                [0.0954, 1.6495, -0.3978],
                [0.1019, 1.7423, -0.5972],
                [-0.2, 0.93, 0.0],
                [-0.2296, 1.3539, -0.176],
                [-0.2419, 1.5292, -0.3677],
                [-0.2478, 1.6135, -0.549],
                [-0.4, 0.8, 0.0],
                [-0.4692, 1.1253, -0.1378],
                [-0.4972, 1.2575, -0.2852],
                [-0.5122, 1.3278, -0.4393],
            ],
            label: "soft", orientation: "camera",
            curls: [0.05901007562281328, 0.15391743106975925, 0.15306695512161833, 0.1523107710627499, 0.15616468442756623],
            gaps: [0.8314850039060827, 0.3686208576008065, 0.375300737264825, 0.40392826700762163],
            thumbExtension: 0.45082252342903484,
            normal: [0.0, -0.0, 1.0],
            confidence: 0.9604061622576101, scoreVsOpen: 84.24942456524747
        ),
        (
            name: "cupped_left", isLeft: true,
            points: [
                [-0.0, 0.0, 0.0],
                [-0.2, 0.2, 0.0],
                [-0.3683, 0.4404, -0.0624],
                [-0.5075, 0.6392, -0.2387],
                [-0.5658, 0.7225, -0.4671],
                [-0.3, 0.95, 0.0],
                [-0.3443, 1.2651, -0.3182],
                [-0.3413, 1.2435, -0.5672],
                [-0.3234, 1.1162, -0.7205],
                [-0.05, 1.0, 0.0],
                [-0.0664, 1.3532, -0.3536],
                [-0.0653, 1.3288, -0.6325],
                [-0.0587, 1.1875, -0.801],
                [0.2, 0.93, 0.0],
                [0.2151, 1.2549, -0.3253],
                [0.2141, 1.2323, -0.5843],
                [0.2081, 1.1039, -0.7375],
                [0.4, 0.8, 0.0],
                [0.4354, 1.0521, -0.2546],
                [0.433, 1.0348, -0.4538],
                [0.4178, 0.9266, -0.584],
            ],
            label: "cupped", orientation: "camera",
            curls: [0.23303971964302378, 0.593433344795243, 0.5910679116667535, 0.5877263947542929, 0.6034260999188161],
            gaps: [0.5265698628376655, 0.28535322644119343, 0.2863537215845756, 0.31420505717622094],
            thumbExtension: 0.582871300218542,
            normal: [0.0, -0.0, 1.0],
            confidence: 0.9718362794371227, scoreVsOpen: 60.55914682100951
        ),
        (
            name: "flat_away", isLeft: false,
            points: [
                [0.0, 0.0, -0.0],
                [-0.2, 0.2, -0.0],
                [-0.2521, 0.4954, -0.0],
                [-0.3042, 0.7909, -0.0],
                [-0.3476, 1.0371, -0.0],
                [-0.3, 0.95, -0.0],
                [-0.3, 1.4, -0.0],
                [-0.3, 1.65, -0.0],
                [-0.3, 1.85, -0.0],
                [-0.05, 1.0, -0.0],
                [-0.05, 1.5, -0.0],
                [-0.05, 1.78, -0.0],
                [-0.05, 2.0, -0.0],
                [0.2, 0.93, 0.0],
                [0.2, 1.39, 0.0],
                [0.2, 1.65, 0.0],
                [0.2, 1.85, 0.0],
                [0.4, 0.8, 0.0],
                [0.4, 1.16, 0.0],
                [0.4, 1.36, 0.0],
                [0.4, 1.53, 0.0],
            ],
            label: "flat", orientation: "away",
            curls: [2.2256163578759924e-09, 0.0, 0.0, 0.0, 0.0],
            gaps: [0.8132764741718506, 0.2911838421430472, 0.2911838421430472, 0.3768884288228395],
            thumbExtension: 0.09913425743660065,
            normal: [0.0, 0.0, -1.0],
            confidence: 0.9519358199548067, scoreVsOpen: 65.40921621246896
        ),
        (
            name: "flat_side", isLeft: false,
            points: [
                [0.0, 0.0, 0.0],
                [0.0, 0.2, -0.2],
                [0.0, 0.4954, -0.2521],
                [0.0, 0.7909, -0.3042],
                [0.0, 1.0371, -0.3476],
                [0.0, 0.95, -0.3],
                [0.0, 1.4, -0.3],
                [0.0, 1.65, -0.3],
                [0.0, 1.85, -0.3],
                [0.0, 1.0, -0.05],
                [0.0, 1.5, -0.05],
                [0.0, 1.78, -0.05],
                [0.0, 2.0, -0.05],
                [-0.0, 0.93, 0.2],
                [-0.0, 1.39, 0.2],
                [-0.0, 1.65, 0.2],
                [-0.0, 1.85, 0.2],
                [-0.0, 0.8, 0.4],
                [-0.0, 1.16, 0.4],
                [-0.0, 1.36, 0.4],
                [-0.0, 1.53, 0.4],
            ],
            label: "flat", orientation: "sideways",
            curls: [2.2256163578759924e-09, 0.0, 0.0, 0.0, 0.0],
            gaps: [0.8132764741718506, 0.2911838421430472, 0.2911838421430472, 0.3768884288228395],
            thumbExtension: 0.09913425743660065,
            normal: [1.0, 0.0, 0.0],
            confidence: 0.9519358199548067, scoreVsOpen: 75.40921621246896
        ),
    ]

    private static func vectors(_ rows: [[Double]]) -> [Vec3] {
        rows.map { Vec3($0[0], $0[1], $0[2]) }
    }

    private func features(_ name: String) -> HandStyling.Features {
        let fx = Self.fixtures.first { $0.name == name }!
        return HandStyling.extractFeatures(points: Self.vectors(fx.points), isLeft: fx.isLeft)!
    }

    func testFixtureParityValues() {
        let reference = features("open")
        for fx in Self.fixtures {
            let feats = features(fx.name)
            let shape = HandStyling.classify(feats)
            XCTAssertEqual(shape.label.rawValue, fx.label, fx.name)
            XCTAssertEqual(feats.palmOrientation.rawValue, fx.orientation, fx.name)
            for (a, b) in zip(feats.curls, fx.curls) { XCTAssertEqual(a, b, accuracy: 1e-9, fx.name) }
            for (a, b) in zip(feats.gaps, fx.gaps) { XCTAssertEqual(a, b, accuracy: 1e-9, fx.name) }
            XCTAssertEqual(feats.thumbExtension, fx.thumbExtension, accuracy: 1e-9, fx.name)
            XCTAssertEqual(feats.palmNormal.x, fx.normal[0], accuracy: 1e-9, fx.name)
            XCTAssertEqual(feats.palmNormal.y, fx.normal[1], accuracy: 1e-9, fx.name)
            XCTAssertEqual(feats.palmNormal.z, fx.normal[2], accuracy: 1e-9, fx.name)
            XCTAssertEqual(shape.confidence, fx.confidence, accuracy: 1e-9, fx.name)
            XCTAssertEqual(HandStyling.compare(feats, reference), fx.scoreVsOpen, accuracy: 1e-9, fx.name)
        }
    }

    func testLeftHandMirrorsToRight() {
        XCTAssertEqual(HandStyling.compare(features("cupped_left"), features("cupped")), 100.0, accuracy: 1e-9)
    }

    func testScaleAndTranslationInvariance() {
        let fx = Self.fixtures.first { $0.name == "fist" }!
        let moved = Self.vectors(fx.points).map { Vec3(2.0 * $0.x + 5.0, 2.0 * $0.y - 3.0, 2.0 * $0.z + 1.0) }
        let a = features("fist")
        let b = HandStyling.extractFeatures(points: moved)!
        XCTAssertEqual(HandStyling.compare(a, b), 100.0, accuracy: 1e-6)
    }

    func testIdenticalIs100AndDifferentIsLower() {
        let open = features("open")
        XCTAssertEqual(HandStyling.compare(open, open), 100.0, accuracy: 1e-9)
        XCTAssertLessThan(HandStyling.compare(open, features("fist")), 50.0)
    }

    func testDegenerateInputIsRejected() {
        XCTAssertNil(HandStyling.normalize(points: Array(repeating: Vec3(0, 0, 0), count: 21)))
        XCTAssertNil(HandStyling.extractFeatures(points: Array(repeating: Vec3(0, 0, 0), count: 5)))
    }
}
