import XCTest
@testable import GrooveCore

final class CanonicalSkeletonTests: XCTestCase {

    private func repoFile(_ relative: String) -> URL {
        // .../ios/GrooveCore/Tests/GrooveCoreTests/<this file> -> repo root
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url.appendingPathComponent(relative)
    }

    private func loadFixtureFrames() throws -> [[String: Any]] {
        let data = try Data(contentsOf: repoFile("fixtures/mediapipe_sample_frames.json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["frames"] as? [[String: Any]])
    }

    private func doubles(_ any: Any?) -> [Double] {
        (any as? [Any] ?? []).map { ($0 as? NSNumber)?.doubleValue ?? .nan }
    }

    private func points(_ any: Any?) -> [[Double]] {
        (any as? [Any] ?? []).map { doubles($0) }
    }

    func testFixtureFramesMatchPythonExpectedCanonical() throws {
        let frames = try loadFixtureFrames()
        XCTAssertFalse(frames.isEmpty)
        for fixture in frames {
            let expected = try XCTUnwrap(fixture["expected_canonical"] as? [String: Any])
            let t = try XCTUnwrap((fixture["t"] as? NSNumber)?.doubleValue)
            let frame = try CanonicalSkeleton.toCanonical(
                worldLandmarks: points(fixture["world_landmarks"]),
                visibility: doubles(fixture["visibility"]),
                t: t
            )
            let expJoints = try XCTUnwrap(expected["joints"] as? [String: Any])
            let expConf = try XCTUnwrap(expected["confidences"] as? [String: Any])
            XCTAssertEqual(Set(frame.joints.keys), Set(expJoints.keys))
            XCTAssertEqual(Set((frame.confidences ?? [:]).keys), Set(expConf.keys))
            XCTAssertEqual(frame.t, (expected["t"] as? NSNumber)?.doubleValue ?? .nan, accuracy: 1e-9)
            XCTAssertNil(frame.hands)
            for (name, exp) in expJoints {
                let got = try XCTUnwrap(frame.joints[name])
                let want = doubles(exp)
                XCTAssertEqual(got.count, 3)
                for k in 0..<3 { XCTAssertEqual(got[k], want[k], accuracy: 1e-9, "\(name)[\(k)]") }
            }
            for (name, exp) in expConf {
                XCTAssertEqual(frame.confidences?[name] ?? .nan, (exp as? NSNumber)?.doubleValue ?? .nan, accuracy: 1e-9, name)
            }
            XCTAssertEqual(frame.joints["root"], [0.0, 0.0, 0.0])
        }
    }

    func testRejectsWrongLandmarkCount() {
        XCTAssertThrowsError(try CanonicalSkeleton.toCanonical(worldLandmarks: [], visibility: [])) {
            XCTAssertEqual($0 as? CanonicalSkeleton.Error, .badPoseLandmarkCount)
        }
    }

    func testBoneLengthsCoverEveryBone() throws {
        let fixture = try XCTUnwrap(loadFixtureFrames().first)
        let frame = try CanonicalSkeleton.toCanonical(
            worldLandmarks: points(fixture["world_landmarks"]), visibility: doubles(fixture["visibility"])
        )
        let lengths = CanonicalSkeleton.boneLengths(frame)
        XCTAssertEqual(lengths.count, CanonicalSkeleton.canonicalBones.count)
        XCTAssertTrue(lengths.values.allSatisfy { $0 > 0.0 })
    }

    // MARK: hands

    private func syntheticPose() -> (world: [[Double]], vis: [Double], image: [[Double]]) {
        var world = [[Double]](repeating: [0.0, 0.0, 0.0], count: 33)
        var image = [[Double]](repeating: [0.5, 0.5, 0.0], count: 33)
        world[15] = [0.3, -0.2, -0.1]
        world[16] = [-0.3, -0.2, -0.1]
        image[15] = [0.7, 0.4, 0.0]
        image[16] = [0.3, 0.4, 0.0]
        return (world, [Double](repeating: 0.9, count: 33), image)
    }

    private func hand(wristImage: [Double], offset: Double) -> CanonicalSkeleton.Hand {
        let world: [[Double]] = (0..<21).map { (i: Int) -> [Double] in
            let d = Double(i)
            return [offset + d * 0.01, 0.1 * d, -0.02 * d]
        }
        let image: [[Double]] = (0..<21).map { (i: Int) -> [Double] in
            let d = Double(i)
            return [wristImage[0] + 0.001 * d, wristImage[1], 0.0]
        }
        return CanonicalSkeleton.Hand(worldLandmarks: world, imageLandmarks: image)
    }

    func testHandsAreAssignedByNearestWristNotByOrder() throws {
        let pose = syntheticPose()
        // Hand 0 is near the pose's right wrist (image x 0.3), hand 1 near the left (x 0.7).
        let hands = [hand(wristImage: [0.31, 0.4], offset: 1.0), hand(wristImage: [0.69, 0.4], offset: 2.0)]
        let frame = try CanonicalSkeleton.toCanonical(
            worldLandmarks: pose.world, visibility: pose.vis, hands: hands, imageLandmarks: pose.image
        )
        let out = try XCTUnwrap(frame.hands)
        XCTAssertEqual(Set(out.keys), ["left", "right"])
        // Landmark 0 sits exactly on that side's pose wrist.
        XCTAssertEqual(try XCTUnwrap(out["left"])[0], try XCTUnwrap(frame.joints["leftWrist"]))
        XCTAssertEqual(try XCTUnwrap(out["right"])[0], try XCTUnwrap(frame.joints["rightWrist"]))
        // left <- hand 1: its landmark 1 is wrist + (flip(p1) - flip(p0)).
        let leftWrist = try XCTUnwrap(frame.joints["leftWrist"])
        let l1 = try XCTUnwrap(out["left"])[1]
        XCTAssertEqual(l1[0], leftWrist[0] + 0.01, accuracy: 1e-12)
        XCTAssertEqual(l1[1], leftWrist[1] - 0.1, accuracy: 1e-12)
        XCTAssertEqual(l1[2], leftWrist[2] + 0.02, accuracy: 1e-12)
    }

    func testSingleHandGoesToNearerWristAndHandsNeedImageLandmarks() throws {
        let pose = syntheticPose()
        let h = hand(wristImage: [0.29, 0.4], offset: 0.0)
        let frame = try CanonicalSkeleton.toCanonical(
            worldLandmarks: pose.world, visibility: pose.vis, hands: [h], imageLandmarks: pose.image
        )
        XCTAssertEqual(Set(try XCTUnwrap(frame.hands).keys), ["right"])
        XCTAssertThrowsError(try CanonicalSkeleton.toCanonical(worldLandmarks: pose.world, visibility: pose.vis, hands: [h])) {
            XCTAssertEqual($0 as? CanonicalSkeleton.Error, .handsNeedImageLandmarks)
        }
    }
}
