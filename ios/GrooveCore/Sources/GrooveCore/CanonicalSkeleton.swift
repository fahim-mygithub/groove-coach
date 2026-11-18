import Foundation

/// MediaPipe world landmarks -> canonical skeleton `groove.canonical/1` (spec §3.1).
///
/// Port of `groove_eval/canonical_skeleton.py`: same joint table, same operation order, so both sides produce the
/// same frames for `fixtures/mediapipe_sample_frames.json`. Metres, root-relative, +x right, +y up, +z toward the
/// camera. Operation order:
/// 1. flip every landmark (x, y, z) -> (x, -y, -z);
/// 2. synthesize root = mid(23, 24), centerShoulder = mid(11, 12), spine = mid(root, centerShoulder),
///    with mid(a, b) = (a + b) * 0.5 per axis;
/// 3. subtract root from every joint.
public enum CanonicalSkeleton {

    public static let skeletonID = "groove.canonical/1"
    public static let poseLandmarkCount = 33
    public static let handLandmarkCount = 21

    /// Canonical joint -> MediaPipe PoseLandmarker index.
    public static let mediapipeIndex: [String: Int] = [
        "nose": 0,
        "leftShoulder": 11, "rightShoulder": 12,
        "leftElbow": 13, "rightElbow": 14,
        "leftWrist": 15, "rightWrist": 16,
        "leftHip": 23, "rightHip": 24,
        "leftKnee": 25, "rightKnee": 26,
        "leftAnkle": 27, "rightAnkle": 28,
        "leftHeel": 29, "rightHeel": 30,
        "leftFootIndex": 31, "rightFootIndex": 32
    ]

    /// Synthesized joint -> the MediaPipe indices it is built from (confidence = min visibility of those).
    public static let synthesizedSources: [String: [Int]] = [
        "root": [23, 24],
        "centerShoulder": [11, 12],
        "spine": [11, 12, 23, 24]
    ]

    public static let canonicalJoints: [String] = [
        "root", "spine", "centerShoulder",
        "leftHip", "leftKnee", "leftAnkle",
        "rightHip", "rightKnee", "rightAnkle",
        "leftShoulder", "leftElbow", "leftWrist",
        "rightShoulder", "rightElbow", "rightWrist",
        "leftHeel", "leftFootIndex", "rightHeel", "rightFootIndex",
        "nose"
    ]

    /// (child, parent) bones of the canonical tree rooted at `root`.
    public static let canonicalBones: [(child: String, parent: String)] = [
        ("spine", "root"), ("centerShoulder", "spine"), ("nose", "centerShoulder"),
        ("leftHip", "root"), ("leftKnee", "leftHip"), ("leftAnkle", "leftKnee"),
        ("leftHeel", "leftAnkle"), ("leftFootIndex", "leftAnkle"),
        ("rightHip", "root"), ("rightKnee", "rightHip"), ("rightAnkle", "rightKnee"),
        ("rightHeel", "rightAnkle"), ("rightFootIndex", "rightAnkle"),
        ("leftShoulder", "centerShoulder"), ("leftElbow", "leftShoulder"), ("leftWrist", "leftElbow"),
        ("rightShoulder", "centerShoulder"), ("rightElbow", "rightShoulder"), ("rightWrist", "rightElbow")
    ]

    public enum Error: Swift.Error, Equatable {
        case badPoseLandmarkCount
        case badHandLandmarkCount
        case handsNeedImageLandmarks
    }

    /// One HandLandmarker result: 21 world landmarks and 21 normalized image landmarks.
    public struct Hand: Sendable {
        public var worldLandmarks: [[Double]]
        public var imageLandmarks: [[Double]]

        public init(worldLandmarks: [[Double]], imageLandmarks: [[Double]]) {
            self.worldLandmarks = worldLandmarks
            self.imageLandmarks = imageLandmarks
        }
    }

    /// MediaPipe world axes (+y down, -z toward camera) -> canonical axes (+y up, +z toward camera).
    public static func mediapipeAxes(_ p: [Double]) -> [Double] {
        [p[0], -p[1], -p[2]]
    }

    private static func mid(_ a: [Double], _ b: [Double]) -> [Double] {
        [(a[0] + b[0]) * 0.5, (a[1] + b[1]) * 0.5, (a[2] + b[2]) * 0.5]
    }

    private static func clamp01(_ x: Double) -> Double {
        max(0.0, min(1.0, x))
    }

    /// Side -> hand index by nearest pose wrist in image space (never by handedness label). With two or more
    /// hands the (left, right) pair with the smallest summed distance wins, ties keep the earlier (i, j) pair.
    /// A single hand goes to its nearer wrist (left on a tie).
    static func assignHands(hands: [Hand], imageLandmarks: [[Double]], imageAspect: Double) -> [String: Int] {
        let wrists = [
            "left": imageLandmarks[mediapipeIndex["leftWrist"]!],
            "right": imageLandmarks[mediapipeIndex["rightWrist"]!]
        ]
        func dist(_ handIdx: Int, _ side: String) -> Double {
            let h = hands[handIdx].imageLandmarks[0]
            let w = wrists[side]!
            let dx = (h[0] - w[0]) * imageAspect
            let dy = h[1] - w[1]
            return (dx * dx + dy * dy).squareRoot()
        }
        if hands.count == 1 {
            return dist(0, "left") <= dist(0, "right") ? ["left": 0] : ["right": 0]
        }
        var best: (total: Double, i: Int, j: Int)?
        for i in 0..<hands.count {
            for j in 0..<hands.count where i != j {
                let total = dist(i, "left") + dist(j, "right")
                if best == nil || total < best!.total {
                    best = (total, i, j)
                }
            }
        }
        return ["left": best!.i, "right": best!.j]
    }

    /// One MediaPipe pose result -> one canonical frame.
    public static func toCanonical(
        worldLandmarks: [[Double]],
        visibility: [Double],
        hands: [Hand] = [],
        t: Double = 0.0,
        imageLandmarks: [[Double]]? = nil,
        imageAspect: Double = 1.0
    ) throws -> GrooveScoringEngine.RawPoseFrame {
        guard worldLandmarks.count == poseLandmarkCount, visibility.count == poseLandmarkCount else {
            throw Error.badPoseLandmarkCount
        }
        let flipped = worldLandmarks.map(mediapipeAxes)
        let root = mid(flipped[23], flipped[24])
        let centerShoulder = mid(flipped[11], flipped[12])
        var absolute: [String: [Double]] = [
            "root": root,
            "spine": mid(root, centerShoulder),
            "centerShoulder": centerShoulder
        ]
        for (name, idx) in mediapipeIndex {
            absolute[name] = flipped[idx]
        }

        var joints: [String: [Double]] = [:]
        var confidences: [String: Double] = [:]
        for name in canonicalJoints {
            let p = absolute[name]!
            joints[name] = [p[0] - root[0], p[1] - root[1], p[2] - root[2]]
            let sources = synthesizedSources[name] ?? [mediapipeIndex[name]!]
            confidences[name] = sources.map { clamp01(visibility[$0]) }.min()!
        }

        var outHands: [String: [[Double]]]?
        if !hands.isEmpty {
            guard let image = imageLandmarks, image.count == poseLandmarkCount else {
                throw Error.handsNeedImageLandmarks
            }
            for h in hands where h.worldLandmarks.count != handLandmarkCount || h.imageLandmarks.count != handLandmarkCount {
                throw Error.badHandLandmarkCount
            }
            var result: [String: [[Double]]] = [:]
            for (side, idx) in assignHands(hands: hands, imageLandmarks: image, imageAspect: imageAspect) {
                let pts = hands[idx].worldLandmarks.map(mediapipeAxes)
                let w = joints[side + "Wrist"]!
                let h0 = pts[0]
                result[side] = pts.map { [w[0] + ($0[0] - h0[0]), w[1] + ($0[1] - h0[1]), w[2] + ($0[2] - h0[2])] }
            }
            outHands = result
        }

        return GrooveScoringEngine.RawPoseFrame(t: t, joints: joints, confidences: confidences, hands: outHands)
    }

    /// Length (m) of every canonical bone present in a frame, keyed by child joint.
    public static func boneLengths(_ frame: GrooveScoringEngine.RawPoseFrame) -> [String: Double] {
        var out: [String: Double] = [:]
        for (child, parent) in canonicalBones {
            guard let c = frame.joints[child], let p = frame.joints[parent] else { continue }
            let d0 = c[0] - p[0], d1 = c[1] - p[1], d2 = c[2] - p[2]
            out[child] = (d0 * d0 + d1 * d1 + d2 * d2).squareRoot()
        }
        return out
    }
}
