import CoreGraphics
import GrooveCore
import Vision

/// Apple Vision hand landmarks (`VNDetectHumanHandPoseRequest`, no extra dependency) mapped to the 21-point
/// MediaPipe Hands order used by `HandStyling` and `RawPoseFrame.hands`.
enum HandPoseExtractor {
    /// Vision joint names in MediaPipe order: wrist, thumb CMC/MP/IP/tip, then MCP/PIP/DIP/tip for index, middle,
    /// ring and little (MediaPipe "pinky").
    static let jointOrder: [VNHumanHandPoseObservation.JointName] = [
        .wrist,
        .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
        .indexMCP, .indexPIP, .indexDIP, .indexTip,
        .middleMCP, .middlePIP, .middleDIP, .middleTip,
        .ringMCP, .ringPIP, .ringDIP, .ringTip,
        .littleMCP, .littlePIP, .littleDIP, .littleTip
    ]

    /// A hand is only used when every one of its 21 joints clears this confidence (otherwise it is "not seen").
    static let minJointConfidence: Float = 0.3

    struct Hand {
        /// "left" / "right" (the dancer's hand, from Vision chirality).
        let side: String
        /// 21 points [x * imageAspect, y, 0] in Vision's normalised image space (y up), so both axes share a unit.
        let points: [[Double]]
        /// Wrist in normalised image coordinates (0...1, y up).
        let wrist: CGPoint
        let wristConfidence: Double
        let meanConfidence: Double
    }

    static func makeRequest() -> VNDetectHumanHandPoseRequest {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        return request
    }

    /// Hands found by an already performed request. `imageAspect` is width / height of the (oriented) image.
    static func hands(from request: VNDetectHumanHandPoseRequest, imageAspect: Double) -> [Hand] {
        var out: [Hand] = []
        for observation in request.results ?? [] {
            guard let recognized = try? observation.recognizedPoints(.all),
                  let wrist = recognized[.wrist] else { continue }
            var points: [[Double]] = []
            var confidenceSum = 0.0
            for name in jointOrder {
                guard let p = recognized[name], p.confidence >= minJointConfidence else { break }
                points.append([Double(p.location.x) * imageAspect, Double(p.location.y), 0.0])
                confidenceSum += Double(p.confidence)
            }
            guard points.count == HandStyling.landmarkCount else { continue }
            let side: String
            switch observation.chirality {
            case .left: side = "left"
            case .right: side = "right"
            default: side = wrist.location.x < 0.5 ? "right" : "left"
            }
            guard !out.contains(where: { $0.side == side }) else { continue }
            out.append(Hand(
                side: side,
                points: points,
                wrist: wrist.location,
                wristConfidence: Double(wrist.confidence),
                meanConfidence: confidenceSum / Double(points.count)
            ))
        }
        return out
    }

    /// `RawPoseFrame.hands` payload, or nil when no usable hand was seen (hand styling is then skipped, not zeroed).
    static func handsPayload(_ hands: [Hand]) -> [String: [[Double]]]? {
        guard !hands.isEmpty else { return nil }
        var payload: [String: [[Double]]] = [:]
        for hand in hands { payload[hand.side] = hand.points }
        return payload
    }

    /// Live hand-shape label ("open", "fist", ...) for one hand.
    static func shapeLabel(_ hand: Hand) -> HandStyling.Shape {
        let vecs = hand.points.map { GrooveScoringEngine.Vec3(array: $0) }
        guard let features = HandStyling.extractFeatures(points: vecs, isLeft: hand.side == "left") else { return .unknown }
        return HandStyling.classify(features).label
    }
}
