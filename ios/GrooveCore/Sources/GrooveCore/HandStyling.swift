import Foundation

/// Hand and finger styling analysis for Groove Coach (standalone, Foundation only).
/// Numeric mirror of `groove_eval/hand_styling.py`.
///
/// Works on 21-point hand landmarks in MediaPipe Hands order. Apple Vision's
/// `VNHumanHandPoseObservation` joints use the same ordering (Vision calls the thumb's first knuckle
/// `MP` where MediaPipe says `MCP`, and the pinky "little"):
///
///     idx   MediaPipe                Apple Vision
///     0     WRIST                    wrist
///     1-4   THUMB_CMC,MCP,IP,TIP     thumbCMC,thumbMP,thumbIP,thumbTip
///     5-8   INDEX_MCP,PIP,DIP,TIP    indexMCP,indexPIP,indexDIP,indexTip
///     9-12  MIDDLE_*                 middle*
///     13-16 RING_*                   ring*
///     17-20 PINKY_*                  little*
///
/// Coordinate convention (after mirroring a left hand to a right hand): x to the viewer's right,
/// y up, z toward the camera. A right hand held fingers-up with the palm to the camera has a
/// palm normal of +z.
public enum HandStyling {

    public typealias Vec3 = GrooveScoringEngine.Vec3

    public static let landmarkCount = 21
    static let wrist = 0
    static let thumbTip = 4
    static let indexMCP = 5
    static let middleMCP = 9
    static let pinkyMCP = 17
    /// (first joint, tip) landmark index per finger: thumb, index, middle, ring, pinky.
    static let fingerChains: [(first: Int, tip: Int)] = [(1, 4), (5, 8), (9, 12), (13, 16), (17, 20)]
    static let fingertips = [4, 8, 12, 16, 20]

    public enum Shape: String, Sendable, CaseIterable {
        case open, flat, fist, cupped, point, soft
        case unknown
    }

    public enum PalmOrientation: String, Sendable {
        case camera, away, sideways
    }

    /// Per shape: thumb, index, middle, ring, pinky curl, mean of the 3 finger-finger gaps, thumb extension.
    static let shapePrototypes: [(shape: Shape, values: [Double])] = [
        (.open, [0.0, 0.0, 0.0, 0.0, 0.0, 0.58, 0.60]),
        (.flat, [0.0, 0.0, 0.0, 0.0, 0.0, 0.32, 0.15]),
        (.fist, [0.6, 1.0, 1.0, 1.0, 1.0, 0.25, 0.75]),
        (.cupped, [0.25, 0.6, 0.6, 0.6, 0.6, 0.30, 0.60]),
        (.point, [0.6, 0.0, 1.0, 1.0, 1.0, 0.55, 0.75]),
        (.soft, [0.1, 0.15, 0.15, 0.15, 0.15, 0.38, 0.45]),
    ]

    public struct Features: Sendable {
        /// Curl 0...1 for thumb, index, middle, ring, pinky.
        public var curls: [Double]
        /// Fingertip gaps (in hand sizes): thumb-index, index-middle, middle-ring, ring-pinky.
        public var gaps: [Double]
        public var thumbExtension: Double
        public var palmNormal: Vec3
        public var palmOrientation: PalmOrientation
    }

    public struct ShapeResult: Sendable {
        public var label: Shape
        public var confidence: Double
        public var scores: [Shape: Double]
    }

    /// Tunable constants; the defaults match `groove_eval/hand_styling.py`.
    public struct Config: Sendable {
        /// 1 - straightness at which a finger counts as fully curled.
        public var curlRange = 0.3
        /// Thumb tip -> index MCP distance (in hand sizes) that counts as fully extended.
        public var thumbExtensionRef = 1.0
        /// Palm normal z beyond +/- this = facing camera / away.
        public var orientationThreshold = 0.5
        /// RMS prototype distance at which a shape score reaches 0.
        public var shapeTolerance = 0.4
        /// Below this confidence the label is `.unknown`.
        public var minConfidence = 0.25
        /// Weights for curl, gap, thumb extension, orientation differences.
        public var compareWeights = [0.5, 0.2, 0.1, 0.2]
        /// Mean gap difference (in hand sizes) that counts as fully different.
        public var gapScale = 0.5

        public init() {}
    }

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        max(lo, min(hi, v))
    }

    private static func sub(_ a: Vec3, _ b: Vec3) -> Vec3 {
        Vec3(a.x - b.x, a.y - b.y, a.z - b.z)
    }

    private static func dist(_ a: Vec3, _ b: Vec3) -> Double {
        sub(a, b).norm
    }

    private static func cross(_ a: Vec3, _ b: Vec3) -> Vec3 {
        Vec3(
            a.y * b.z - a.z * b.y,
            a.z * b.x - a.x * b.z,
            a.x * b.y - a.y * b.x
        )
    }

    /// Translate to the wrist, scale by wrist -> middle-MCP distance, mirror left hands to right.
    /// Returns nil if there are not 21 points or the hand has no size.
    public static func normalize(points: [Vec3], isLeft: Bool = false) -> [Vec3]? {
        guard points.count == landmarkCount else { return nil }
        let origin = points[wrist]
        let size = dist(points[middleMCP], origin)
        guard size >= 1e-9 else { return nil }
        let sign = isLeft ? -1.0 : 1.0
        return points.map { p in
            let d = sub(p, origin)
            return Vec3(sign * d.x / size, d.y / size, d.z / size)
        }
    }

    /// Curl 0...1 for finger 0...4 of a normalised hand. Straightness = chord(first joint, tip) / summed
    /// segment lengths: 1 when straight, lower when bent.
    public static func fingerCurl(hand: [Vec3], finger: Int, curlRange: Double = Config().curlRange) -> Double {
        let chain = fingerChains[finger]
        var path = 0.0
        for i in chain.first..<chain.tip {
            path += dist(hand[i + 1], hand[i])
        }
        guard path >= 1e-9 else { return 0.0 }
        let straightness = dist(hand[chain.tip], hand[chain.first]) / path
        return clamp((1.0 - straightness) / curlRange, 0.0, 1.0)
    }

    /// Unit palm normal: (index MCP - wrist) x (pinky MCP - wrist) of a normalised (right) hand.
    public static func palmNormal(hand: [Vec3]) -> Vec3 {
        cross(sub(hand[indexMCP], hand[wrist]), sub(hand[pinkyMCP], hand[wrist])).normalized
    }

    public static func palmOrientation(normal: Vec3, threshold: Double = Config().orientationThreshold) -> PalmOrientation {
        if normal.z > threshold { return .camera }
        if normal.z < -threshold { return .away }
        return .sideways
    }

    /// Features of one hand, or nil if the landmarks are unusable.
    public static func extractFeatures(points: [Vec3], isLeft: Bool = false, config: Config = Config()) -> Features? {
        guard let hand = normalize(points: points, isLeft: isLeft) else { return nil }
        let curls = (0..<5).map { fingerCurl(hand: hand, finger: $0, curlRange: config.curlRange) }
        let gaps = (0..<4).map { dist(hand[fingertips[$0]], hand[fingertips[$0 + 1]]) }
        let thumbExtension = clamp(dist(hand[thumbTip], hand[indexMCP]) / config.thumbExtensionRef, 0.0, 1.0)
        let normal = palmNormal(hand: hand)
        return Features(
            curls: curls,
            gaps: gaps,
            thumbExtension: thumbExtension,
            palmNormal: normal,
            palmOrientation: palmOrientation(normal: normal, threshold: config.orientationThreshold)
        )
    }

    /// Best-matching dance hand shape. Each shape scores 1 - rms(feature - prototype) / tolerance,
    /// clamped to 0...1; the confidence is the best score and the label is `.unknown` below `minConfidence`.
    public static func classify(_ features: Features, config: Config = Config()) -> ShapeResult {
        let vec = features.curls + [(features.gaps[1] + features.gaps[2] + features.gaps[3]) / 3.0, features.thumbExtension]
        var scores: [Shape: Double] = [:]
        var bestShape = shapePrototypes[0].shape
        var bestScore = -1.0
        for proto in shapePrototypes {
            var sq = 0.0
            for (a, b) in zip(vec, proto.values) {
                sq += (a - b) * (a - b)
            }
            let rms = (sq / Double(proto.values.count)).squareRoot()
            let score = clamp(1.0 - rms / config.shapeTolerance, 0.0, 1.0)
            scores[proto.shape] = score
            if score > bestScore {
                bestScore = score
                bestShape = proto.shape
            }
        }
        return ShapeResult(
            label: bestScore >= config.minConfidence ? bestShape : .unknown,
            confidence: bestScore,
            scores: scores
        )
    }

    /// Similarity 0-100 between learner and reference hand features (100 = identical shape). Weighted
    /// sum of mean curl difference, mean gap difference / gapScale, thumb-extension difference and
    /// palm-normal angle / pi.
    public static func compare(_ learner: Features, _ reference: Features, config: Config = Config()) -> Double {
        var curlSum = 0.0
        for (a, b) in zip(learner.curls, reference.curls) { curlSum += abs(a - b) }
        var gapSum = 0.0
        for (a, b) in zip(learner.gaps, reference.gaps) { gapSum += abs(a - b) }
        let curlD = curlSum / 5.0
        let gapD = clamp(gapSum / 4.0 / config.gapScale, 0.0, 1.0)
        let thumbD = abs(learner.thumbExtension - reference.thumbExtension)
        let ln = learner.palmNormal
        let rn = reference.palmNormal
        let cosAngle = clamp(ln.x * rn.x + ln.y * rn.y + ln.z * rn.z, -1.0, 1.0)
        let orientD = acos(cosAngle) / Double.pi
        let w = config.compareWeights
        let total = w[0] * curlD + w[1] * gapD + w[2] * clamp(thumbD, 0.0, 1.0) + w[3] * orientD
        return 100.0 * clamp(1.0 - total, 0.0, 1.0)
    }
}
