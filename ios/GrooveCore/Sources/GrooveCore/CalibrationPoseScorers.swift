import Foundation

// Stateless dance-calibration v2 pose evaluators (Poses 1–9), FoV/LiDAR distance & coupled span geometry,
// shared hold/dropout tracker, and metric/ROM/confidence aggregators.
// Pure Foundation so `swift test --package-path ios/GrooveCore` runs on Linux CI.
// Spec: docs/specs/2026-11-26-calibration-v2-plan.md (§2.1, §2.2, §3.2, §3.5, §6.1, §7.1, §7.2, §8.1–8.3).

public enum CalibrationPoseScorers {

    // MARK: - Pose Kinds & Diagnostic Cues

    /// The 9 dance calibration poses (with Pose 8 split into `.stepLeft` and `.stepRight`, §2.1).
    public enum PoseKind: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
        case rest
        case tpose
        case overhead
        case asymLR
        case armsForward
        case plie
        case turned45
        case stepLeft
        case stepRight
        case kneeLift

        /// Unified `CalibrationStep` raw index (`stepIndex`, §2.1).
        public var stepIndex: Int {
            switch self {
            case .rest: return 2
            case .tpose: return 4
            case .overhead: return 5
            case .asymLR: return 6
            case .armsForward: return 7
            case .plie: return 8
            case .turned45: return 9
            case .stepLeft: return 10
            case .stepRight: return 11
            case .kneeLift: return 12
            }
        }

        /// Required hold duration in monotonic pose-stream seconds (§2.2, §7.2).
        public func holdDurationS(tuning u: CalibrationTuning = .defaults) -> Double {
            switch self {
            case .rest: return u.restHoldS
            case .tpose: return u.poseHoldS
            case .overhead: return u.overheadHoldS
            case .asymLR: return u.asymHoldS
            case .armsForward: return u.forwardHoldS
            case .plie: return u.plieHoldS
            case .turned45: return u.turnedHoldS
            case .stepLeft, .stepRight: return u.stepHoldS
            case .kneeLift: return u.kneeLiftHoldS
            }
        }

        /// Tolerated dropout duration in seconds (§2.2, §7.2).
        public func dropoutToleranceS(tuning u: CalibrationTuning = .defaults) -> Double {
            switch self {
            case .stepLeft, .stepRight:
                return u.stepDropoutS
            case .kneeLift:
                return u.kneeLiftDropoutS
            case .rest, .tpose, .overhead, .asymLR, .armsForward, .plie, .turned45:
                return u.dropoutToleranceS
            }
        }

        /// Maximum per-sample normalized body motion to start a hold (§2.2, §7.2).
        public func motionEnterMax(tuning u: CalibrationTuning = .defaults) -> Double {
            switch self {
            case .rest, .tpose:
                return u.motionEnterMax
            case .overhead, .asymLR, .armsForward, .turned45:
                return 0.015
            case .plie:
                return 0.018
            case .stepLeft, .stepRight:
                return 0.020
            case .kneeLift:
                return 0.025
            }
        }

        /// Maximum per-sample normalized body motion to stay in a latched hold (§2.2, §7.2).
        public func motionStayMax(tuning u: CalibrationTuning = .defaults) -> Double {
            switch self {
            case .rest, .tpose:
                return u.motionStayMax
            case .overhead, .asymLR, .armsForward, .turned45:
                return 0.025
            case .plie:
                return 0.028
            case .stepLeft, .stepRight:
                return 0.030
            case .kneeLift:
                return u.kneeLiftMotionStayMax
            }
        }

        /// Minimum good samples required before completing the hold (§2.2, §7.2).
        public func minCapturedSamples(tuning u: CalibrationTuning = .defaults) -> Int {
            switch self {
            case .tpose:
                return max(1, u.minCapturedFrames)
            default:
                return 1
            }
        }

        /// Default entry instruction cue for this pose (§2.2).
        public var entryCue: PoseCue {
            switch self {
            case .rest: return .relaxArms
            case .tpose: return .armsOutT
            case .overhead: return .reachOverhead
            case .asymLR: return .asymPose
            case .armsForward: return .armsForward
            case .plie: return .bendKneesDeeper
            case .turned45: return .turnBody45
            case .stepLeft: return .stepLeft
            case .stepRight: return .stepRight
            case .kneeLift: return .liftKnee
            }
        }
    }

    /// Spoken/visual diagnostic cues emitted by v2 framing, LiDAR distance, and Poses 1–9 (§2.2, §3.5).
    public enum PoseCue: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
        case none
        // Framing & LiDAR distance
        case stepIn
        case stepBackDistance
        case stepCloserDistance
        case stepBackShowFeet
        case showHead
        case stepBack
        case stepCloser
        case moveLeft
        case moveRight
        // Pose-specific entry & diagnostic cues
        case relaxArms
        case armsOutT
        case reachOverhead
        case stepBackHeadroom
        case asymPose
        case swapArmsLR
        case armsForward
        case bendKneesDeeper
        case turnBody45
        case turnLessSideways
        case stepLeft
        case stepRight
        case stepBackLateralRoom
        case liftKnee
        case holdStill

        /// Formatted spoken instruction (§2.2, §3.5).
        public func spokenText(
            dancerDistanceM: Double? = nil,
            effectiveMinDistanceM: Double? = nil
        ) -> String {
            switch self {
            case .none:
                return ""
            case .stepIn:
                return "Step in front of the camera."
            case .stepBackDistance:
                let targetM = CalibrationPoseScorers.spokenTargetMinDistanceM(
                    for: effectiveMinDistanceM ?? 2.5
                )
                let targetStr = String(format: "%.1f", targetM)
                if let current = dancerDistanceM, current.isFinite, current > 0 {
                    let curStr = String(format: "%.1f", current)
                    return "You're at \(curStr) meters—step back to about \(targetStr) meters so your arms and steps fit in frame."
                }
                return "Step back to about \(targetStr) meters so your arms and steps fit in frame."
            case .stepCloserDistance:
                return "You're over 4 meters away—step a little closer."
            case .stepBackShowFeet:
                return "Step back so your feet are in view."
            case .showHead:
                return "Step back so your head is in view."
            case .stepBack:
                return "Step back slightly so both hands stay in view."
            case .stepCloser:
                return "Step a little closer."
            case .moveLeft:
                return "Move to your left."
            case .moveRight:
                return "Move to your right."
            case .relaxArms:
                return "Stand centered in the box, feet visible, arms relaxed by your sides."
            case .armsOutT:
                return "Arms straight out to the sides, like a T. Hold still."
            case .reachOverhead:
                return "Reach both arms straight up overhead."
            case .stepBackHeadroom:
                return "Step back a little so your raised hands stay in frame."
            case .asymPose:
                return "Raise your left arm straight up, and stretch your right arm out to the side."
            case .swapArmsLR:
                return "Other side—raise your left arm up, right arm out."
            case .armsForward:
                return "Bring both hands up to shoulder height, pointing at the lens."
            case .bendKneesDeeper:
                return "Bend your knees a little deeper, heels in view."
            case .turnBody45:
                return "Keep arms out and turn your whole body halfway to one side."
            case .turnLessSideways:
                return "Turn a little less sideways so both shoulders are visible."
            case .stepLeft:
                return "Take a wide dance step to your left and pause."
            case .stepRight:
                return "Now take a wide step to your right and pause."
            case .stepBackLateralRoom:
                return "Step back slightly for more side-to-side room."
            case .liftKnee:
                return "Lift one knee up toward hip height for a moment."
            case .holdStill:
                return "Hold still."
            }
        }

        /// Maps directly representable cues onto v1 `CalibrationCue` (for legacy compatibility).
        public var legacyCue: CalibrationCue? {
            switch self {
            case .none: return .none
            case .stepIn: return .stepIn
            case .stepBackShowFeet: return .stepBackShowFeet
            case .showHead: return .showHead
            case .stepBack, .stepBackDistance, .stepBackHeadroom, .stepBackLateralRoom: return .stepBack
            case .stepCloser, .stepCloserDistance: return .stepCloser
            case .moveLeft: return .moveLeft
            case .moveRight: return .moveRight
            case .armsOutT: return .armsOutT
            case .holdStill: return .holdStill
            default: return nil
            }
        }
    }

    // MARK: - Joint Lists & Internal Geometry Helpers

    public static let coreJoints: [String] = [
        "nose", "leftShoulder", "rightShoulder", "leftHip", "rightHip",
        "leftKnee", "rightKnee", "leftAnkle", "rightAnkle"
    ]
    public static let footJoints: [String] = [
        "leftHeel", "rightHeel", "leftFootIndex", "rightFootIndex"
    ]
    public static let legJoints: [String] = [
        "leftKnee", "rightKnee", "leftAnkle", "rightAnkle"
    ]
    public static let armJoints: [String] = [
        "leftShoulder", "rightShoulder", "leftElbow", "rightElbow", "leftWrist", "rightWrist"
    ]

    /// Fallback portrait vertical FoV (deg) when `videoFieldOfView` reports `0` (§3.2).
    public static let fallbackVerticalFoVDeg: Double = 60.0
    /// Fallback camera height (m) when LiDAR floor height is not yet measured (§1, §3.2).
    public static let defaultCameraHeightM: Double = 0.70

    struct Vec3: Equatable, Sendable {
        var x: Double
        var y: Double
        var z: Double

        init(_ x: Double, _ y: Double, _ z: Double) {
            self.x = x
            self.y = y
            self.z = z
        }

        init(_ a: [Double]) {
            self.init(
                a.count > 0 ? a[0] : 0.0,
                a.count > 1 ? a[1] : 0.0,
                a.count > 2 ? a[2] : 0.0
            )
        }

        init(_ v: CalibrationVector3) {
            self.init(v.x, v.y, v.z)
        }

        var norm: Double {
            (x * x + y * y + z * z).squareRoot()
        }

        var normalized: Vec3 {
            let n = norm
            guard n > 1e-12 else { return Vec3(0, 0, 0) }
            return Vec3(x / n, y / n, z / n)
        }

        static func - (lhs: Vec3, rhs: Vec3) -> Vec3 {
            Vec3(lhs.x - rhs.x, lhs.y - rhs.y, lhs.z - rhs.z)
        }

        static func + (lhs: Vec3, rhs: Vec3) -> Vec3 {
            Vec3(lhs.x + rhs.x, lhs.y + rhs.y, lhs.z + rhs.z)
        }

        static func * (lhs: Vec3, rhs: Double) -> Vec3 {
            Vec3(lhs.x * rhs, lhs.y * rhs, lhs.z * rhs)
        }

        static func dot(_ a: Vec3, _ b: Vec3) -> Double {
            a.x * b.x + a.y * b.y + a.z * b.z
        }

        static func cross(_ a: Vec3, _ b: Vec3) -> Vec3 {
            Vec3(
                a.y * b.z - a.z * b.y,
                a.z * b.x - a.x * b.z,
                a.x * b.y - a.y * b.x
            )
        }
    }

    static func landmark(_ points: [CalibrationLandmark], _ name: String) -> CalibrationLandmark? {
        guard let i = CanonicalSkeleton.mediapipeIndex[name], i < points.count else { return nil }
        return points[i]
    }

    static func visibility(_ points: [CalibrationLandmark], _ name: String) -> Double {
        landmark(points, name)?.visibility ?? 0.0
    }

    static func angle2DDeg(_ a: CalibrationLandmark, _ b: CalibrationLandmark, _ c: CalibrationLandmark) -> Double {
        let v1x = a.x - b.x
        let v1y = a.y - b.y
        let v2x = c.x - b.x
        let v2y = c.y - b.y
        let denom = hypot(v1x, v1y) * hypot(v2x, v2y)
        guard denom > 1e-9 else { return 0.0 }
        let cosVal = max(-1.0, min(1.0, (v1x * v2x + v1y * v2y) / denom))
        return acos(cosVal) * 180.0 / .pi
    }

    static func angleBetween3DDeg(_ u: Vec3, _ v: Vec3) -> Double {
        let un = u.norm
        let vn = v.norm
        guard un > 1e-9, vn > 1e-9 else { return 0.0 }
        let cosVal = max(-1.0, min(1.0, Vec3.dot(u, v) / (un * vn)))
        return acos(cosVal) * 180.0 / .pi
    }

    static func applyGravity(_ point: Vec3, cameraGravity: CalibrationVector3) -> Vec3 {
        let g = Vec3(cameraGravity).normalized
        guard g.norm > 0.5 else { return point }
        let target = Vec3(0.0, -1.0, 0.0)
        let cosTheta = max(-1.0, min(1.0, Vec3.dot(g, target)))
        if cosTheta > 0.999999 { return point }
        if cosTheta < -0.999999 { return Vec3(point.x, -point.y, -point.z) }
        let axis = Vec3.cross(g, target).normalized
        let sinTheta = max(0.0, 1.0 - cosTheta * cosTheta).squareRoot()
        let kDotP = Vec3.dot(axis, point)
        let kCrossP = Vec3.cross(axis, point)
        return point * cosTheta + kCrossP * sinTheta + axis * (kDotP * (1.0 - cosTheta))
    }

    static func gravityAlignedJoints(
        _ frame: GrooveScoringEngine.RawPoseFrame?,
        cameraGravity: CalibrationVector3
    ) -> [String: Vec3] {
        guard let frame else { return [:] }
        var out: [String: Vec3] = [:]
        out.reserveCapacity(frame.joints.count)
        for (name, arr) in frame.joints where arr.count >= 3 {
            out[name] = applyGravity(Vec3(arr), cameraGravity: cameraGravity)
        }
        return out
    }

    static func clamp(_ value: Double, _ lo: Double, _ hi: Double) -> Double {
        max(lo, min(hi, value))
    }

    static func clamp01(_ value: Double) -> Double {
        max(0.0, min(1.0, value))
    }

    static func torsoScale2D(_ pts: [CalibrationLandmark]) -> (shoulder: Double, torso: Double, yScale: Double)? {
        guard let ls = landmark(pts, "leftShoulder"),
              let rs = landmark(pts, "rightShoulder") else { return nil }
        let shoulder = hypot(rs.x - ls.x, rs.y - ls.y)
        guard shoulder > 1e-6 else { return nil }
        var torso = shoulder * 1.2
        if let lh = landmark(pts, "leftHip"),
           let rh = landmark(pts, "rightHip"),
           min(lh.visibility, rh.visibility) > 0 {
            torso = abs(0.5 * (ls.y + rs.y) - 0.5 * (lh.y + rh.y))
        }
        let yScale = max(torso, shoulder * 0.6, 1e-6)
        return (shoulder, torso, yScale)
    }

    static func span2D(_ pts: [CalibrationLandmark]) -> (noseY: Double, maxFootY: Double, span: Double)? {
        guard let noseY = landmark(pts, "nose")?.y,
              let maxFootY = footJoints.compactMap({ landmark(pts, $0)?.y }).max() else {
            return nil
        }
        return (noseY, maxFootY, maxFootY - noseY)
    }

    static func hipCenterX2D(_ pts: [CalibrationLandmark]) -> Double? {
        guard let lh = landmark(pts, "leftHip"), let rh = landmark(pts, "rightHip") else { return nil }
        return 0.5 * (lh.x + rh.x)
    }

    // MARK: - FoV & Reconciled Minimum Studio Distance (§3.2)

    /// Computes `d_effective_min` enforcing **both** vertical FoV headroom (`d_vert_min`) and
    /// narrow portrait horizontal FoV width (`d_horiz_min = (wingspanM + lateralStepMarginM) / (2 * tan(thetaH / 2))`),
    /// clamped into `[2.0, 3.6] m` (§3.2).
    public static func effectiveMinDistanceM(
        hCam: Double = defaultCameraHeightM,
        dancerHeightM: Double = CalibrationProfileV2.defaultDancerHeightM,
        wingspanM: Double? = nil,
        verticalFoVDeg: Double,
        horizontalFoVDeg: Double? = nil,
        tuning u: CalibrationTuning = .defaults
    ) -> Double {
        let resolvedHeight = (dancerHeightM.isFinite && dancerHeightM > 0)
            ? dancerHeightM
            : CalibrationProfileV2.defaultDancerHeightM
        let resolvedHCam = (hCam.isFinite && hCam >= 0) ? hCam : defaultCameraHeightM
        let resolvedWingspan: Double = {
            if let w = wingspanM, w.isFinite, w > 0 { return w }
            return CalibrationProfileV2.defaultWingspanToHeightRatio * resolvedHeight
        }()

        let vFoV = (verticalFoVDeg.isFinite && verticalFoVDeg > 0 && verticalFoVDeg < 180.0)
            ? verticalFoVDeg
            : fallbackVerticalFoVDeg
        let hFoV: Double = {
            if let explicitHFoV = horizontalFoVDeg, explicitHFoV.isFinite, explicitHFoV > 0, explicitHFoV < 180.0 {
                return explicitHFoV
            }
            return CalibrationIntrinsics.portraitHorizontalFoVDeg(fromVerticalFoVDeg: vFoV)
        }()

        let tanHalfV = max(1e-6, tan((vFoV * .pi / 180.0) * 0.5))
        let tanHalfH = max(1e-6, tan((hFoV * .pi / 180.0) * 0.5))

        // 1. Vertical head-to-toe + raised-hands constraint (1.25 * H_dancer, §3.2).
        let verticalExtent = max(resolvedHCam, 1.25 * resolvedHeight - resolvedHCam)
        let dVertMin = verticalExtent / tanHalfV

        // 2. Horizontal T-pose + lateral step width constraint (§3.2).
        let dHorizMin = (resolvedWingspan + u.lateralStepMarginM) / (2.0 * tanHalfH)

        let dGeomMin = max(dVertMin, dHorizMin)
        return clamp(max(u.lidarMinDistanceM, dGeomMin), 2.0, 3.6)
    }

    /// Rounds `effectiveMinDistanceM` up to the nearest `0.5 m` (`ceil(d * 2) / 2`) for dynamic spoken cues (§3.2, §3.5).
    public static func spokenTargetMinDistanceM(for effectiveMinDistanceM: Double) -> Double {
        guard effectiveMinDistanceM.isFinite, effectiveMinDistanceM > 0 else { return 2.5 }
        return (effectiveMinDistanceM * 2.0).rounded(.up) / 2.0
    }

    // MARK: - LiDAR Distance & FoV/Distance-Coupled Framing Span (§3.5)

    /// Coupled 2D `span` bounds produced by `effectiveSpanBounds` (§3.5).
    public struct SpanBounds: Equatable, Sendable {
        /// Pinhole expected standing nose-to-foot 2D span (`nil` when depth or FoV is unavailable).
        public var spanExpected: Double?
        /// Un-widened lower bound before stay/relax hysteresis.
        public var spanMinBase: Double
        /// Un-widened upper bound before stay/relax hysteresis.
        public var spanMaxBase: Double
        /// Active lower bound after stay/relax widening.
        public var spanMinUsed: Double
        /// Active upper bound after stay/relax widening.
        public var spanMaxUsed: Double

        public init(
            spanExpected: Double?,
            spanMinBase: Double,
            spanMaxBase: Double,
            spanMinUsed: Double,
            spanMaxUsed: Double
        ) {
            self.spanExpected = spanExpected
            self.spanMinBase = spanMinBase
            self.spanMaxBase = spanMaxBase
            self.spanMinUsed = spanMinUsed
            self.spanMaxUsed = spanMaxUsed
        }
    }

    /// Computes FoV- and LiDAR-distance-coupled 2D `span` bounds across Mode A (`rearLiDAR` with live depth),
    /// Mode B (monocular with known FoV), and Mode C (no depth & no FoV, e.g. synthetic tests) per §3.5.
    public static func effectiveSpanBounds(
        cameraMode: CameraMode = .frontSelfView,
        calibrationTier: CalibrationResumeTier = .tier2FullCalibration,
        dancerDistanceM: Double? = nil,
        measuredHeightM: Double? = nil,
        storedHeightM: Double? = nil,
        cameraHeightM: Double? = nil,
        wingspanM: Double? = nil,
        verticalFoVDeg: Double? = nil,
        horizontalFoVDeg: Double? = nil,
        passing: Bool = false,
        relaxed: Bool = false,
        tuning u: CalibrationTuning = .defaults
    ) -> SpanBounds {
        let hEst: Double = {
            if let m = measuredHeightM, m.isFinite, m > 0 { return m }
            if let s = storedHeightM, s.isFinite, s > 0 { return s }
            return CalibrationProfileV2.defaultDancerHeightM
        }()

        var spanDelta = 0.0
        if relaxed { spanDelta = max(spanDelta, u.relaxSpanDelta) }
        if passing { spanDelta = max(spanDelta, u.framingStaySpanDelta) }

        let spanFloor = u.spanMinFloor
        let spanCeil = u.spanMax

        // Mode C: No valid vertical FoV -> retuned static [spanMinFloor, spanMax] = [0.22, 0.75].
        guard let vFoV = verticalFoVDeg, vFoV.isFinite, vFoV > 0, vFoV < 180.0 else {
            let minBase = spanFloor
            let maxBase = max(minBase, spanCeil)
            return SpanBounds(
                spanExpected: nil,
                spanMinBase: minBase,
                spanMaxBase: maxBase,
                spanMinUsed: max(0.0, minBase - spanDelta),
                spanMaxUsed: maxBase + spanDelta
            )
        }

        let tanHalfV = max(1e-6, tan((vFoV * .pi / 180.0) * 0.5))

        // Mode A: rearLiDAR with live dancerDistanceM > 0.
        if cameraMode == .rearLiDAR, let d = dancerDistanceM, d.isFinite, d > 0 {
            let expected = (u.noseToFootHeightRatio * hEst) / (2.0 * d * tanHalfV)
            let rawMin = max(spanFloor, (1.0 - u.spanDepthToleranceRatio) * expected)
            let rawMax = min(spanCeil, (1.0 + u.spanDepthToleranceRatio) * expected)
            let minBase = min(rawMin, rawMax)
            let maxBase = max(rawMin, rawMax)
            return SpanBounds(
                spanExpected: expected,
                spanMinBase: minBase,
                spanMaxBase: maxBase,
                spanMinUsed: max(0.0, minBase - spanDelta),
                spanMaxUsed: maxBase + spanDelta
            )
        }

        // Mode B: Monocular (or rearLiDAR warm-up prior to first depth sample) with known vertical FoV.
        let maxDist = max(0.5, u.lidarMaxDistanceM)
        let farFloor = (0.85 * u.noseToFootHeightRatio * hEst) / (2.0 * maxDist * tanHalfV)
        let minBase = min(spanCeil, max(spanFloor, farFloor))

        let capsNearSpan = (cameraMode == .rearWide)
            || (cameraMode == .rearLiDAR)
            || (calibrationTier == .tier2FullCalibration)
        let maxBase: Double
        if capsNearSpan {
            let dEffMin = effectiveMinDistanceM(
                hCam: cameraHeightM ?? defaultCameraHeightM,
                dancerHeightM: hEst,
                wingspanM: wingspanM,
                verticalFoVDeg: vFoV,
                horizontalFoVDeg: horizontalFoVDeg,
                tuning: u
            )
            let spanAtMinDist = (u.noseToFootHeightRatio * hEst) / (2.0 * dEffMin * tanHalfV)
            let nearCap = (1.0 + u.spanDepthToleranceRatio) * spanAtMinDist
            maxBase = max(minBase, min(spanCeil, nearCap))
        } else {
            // Tier-0 / Tier-1 frontSelfView quick resume keeps spanMaxBase = spanMax (0.75).
            maxBase = max(minBase, spanCeil)
        }

        return SpanBounds(
            spanExpected: nil,
            spanMinBase: minBase,
            spanMaxBase: maxBase,
            spanMinUsed: max(0.0, minBase - spanDelta),
            spanMaxUsed: maxBase + spanDelta
        )
    }

    /// Result of evaluating `dancerDistanceM` in `.rearLiDAR` mode (§3.5).
    public struct DistanceEvaluation: Equatable, Sendable {
        public var isActive: Bool
        public var effectiveMinDistanceM: Double
        public var distanceMinUsed: Double
        public var distanceMaxUsed: Double
        public var dancerDistanceM: Double?
        public var distanceOK: Bool
        public var cue: PoseCue

        public init(
            isActive: Bool,
            effectiveMinDistanceM: Double,
            distanceMinUsed: Double,
            distanceMaxUsed: Double,
            dancerDistanceM: Double?,
            distanceOK: Bool,
            cue: PoseCue
        ) {
            self.isActive = isActive
            self.effectiveMinDistanceM = effectiveMinDistanceM
            self.distanceMinUsed = distanceMinUsed
            self.distanceMaxUsed = distanceMaxUsed
            self.dancerDistanceM = dancerDistanceM
            self.distanceOK = distanceOK
            self.cue = cue
        }
    }

    /// Evaluates `[d_effective_min, 4.0 m]` LiDAR distance bounds with stay/relax hysteresis and `< 0.25 s`
    /// warm-up suppression (§3.5).
    public static func evaluateDistance(
        cameraMode: CameraMode,
        dancerDistanceM: Double?,
        measuredHeightM: Double? = nil,
        storedHeightM: Double? = nil,
        cameraHeightM: Double? = nil,
        wingspanM: Double? = nil,
        verticalFoVDeg: Double? = nil,
        horizontalFoVDeg: Double? = nil,
        passing: Bool = false,
        relaxed: Bool = false,
        warmupElapsedS: Double = 0.0,
        tuning u: CalibrationTuning = .defaults
    ) -> DistanceEvaluation {
        let hEst = measuredHeightM ?? storedHeightM ?? CalibrationProfileV2.defaultDancerHeightM
        let dEffMin = effectiveMinDistanceM(
            hCam: cameraHeightM ?? defaultCameraHeightM,
            dancerHeightM: hEst,
            wingspanM: wingspanM,
            verticalFoVDeg: verticalFoVDeg ?? fallbackVerticalFoVDeg,
            horizontalFoVDeg: horizontalFoVDeg,
            tuning: u
        )
        var distDelta = 0.0
        if relaxed { distDelta = max(distDelta, u.lidarDistanceRelaxDeltaM) }
        if passing { distDelta = max(distDelta, u.lidarDistanceStayDeltaM) }

        let minUsed = max(u.lidarMinDistanceM, dEffMin - distDelta)
        let maxUsed = u.lidarMaxDistanceM + distDelta

        guard cameraMode == .rearLiDAR else {
            return DistanceEvaluation(
                isActive: false,
                effectiveMinDistanceM: dEffMin,
                distanceMinUsed: minUsed,
                distanceMaxUsed: maxUsed,
                dancerDistanceM: dancerDistanceM,
                distanceOK: true,
                cue: .none
            )
        }

        guard let d = dancerDistanceM, d.isFinite, d > 0 else {
            // Initial < 0.25 s warm-up before first 5–10 Hz LiDAR sample arrives holds distanceOK = false, cue = .none (§3.5).
            let missingDepthCue: PoseCue = (warmupElapsedS < 0.25) ? .none : .stepCloserDistance
            return DistanceEvaluation(
                isActive: true,
                effectiveMinDistanceM: dEffMin,
                distanceMinUsed: minUsed,
                distanceMaxUsed: maxUsed,
                dancerDistanceM: nil,
                distanceOK: false,
                cue: missingDepthCue
            )
        }

        if d < minUsed {
            return DistanceEvaluation(
                isActive: true,
                effectiveMinDistanceM: dEffMin,
                distanceMinUsed: minUsed,
                distanceMaxUsed: maxUsed,
                dancerDistanceM: d,
                distanceOK: false,
                cue: .stepBackDistance
            )
        }
        if d > maxUsed {
            return DistanceEvaluation(
                isActive: true,
                effectiveMinDistanceM: dEffMin,
                distanceMinUsed: minUsed,
                distanceMaxUsed: maxUsed,
                dancerDistanceM: d,
                distanceOK: false,
                cue: .stepCloserDistance
            )
        }
        return DistanceEvaluation(
            isActive: true,
            effectiveMinDistanceM: dEffMin,
            distanceMinUsed: minUsed,
            distanceMaxUsed: maxUsed,
            dancerDistanceM: d,
            distanceOK: true,
            cue: .none
        )
    }

    // MARK: - Pose 1: `.rest` & v2 Framing Evaluator (§2.2 Pose 1, §3.5, §7.1)

    /// Detailed framing + distance check shared by Pose 1 (`.rest`) and `PoseHoldTracker` (§2.2, §3.5, §7.1).
    public struct FramingEvaluation: Equatable, Sendable {
        public var presence: Bool
        public var coreVisibleOK: Bool
        public var feetVisibleOK: Bool
        public var headVisibleOK: Bool
        public var safeBoxOK: Bool
        public var feetInFrameOK: Bool
        public var headroomOK: Bool
        public var distanceEvaluation: DistanceEvaluation
        public var span: Double?
        public var spanBounds: SpanBounds
        public var spanOK: Bool
        public var hipCenterX: Double?
        public var hipCenterMinUsed: Double
        public var hipCenterMaxUsed: Double
        public var centredOK: Bool
        public var coreFloorUsed: Double
        public var footFloorUsed: Double
        public var minX: Double?
        public var maxX: Double?
        public var noseY: Double?
        public var maxFootY: Double?
        public var passes: Bool
        public var cue: PoseCue
    }

    /// Evaluates full-body framing with LiDAR distance-before-span precedence, FoV/distance-coupled `span`,
    /// Tier-2 `[0.40, 0.60]` centring, `.stepLeft`/`.stepRight` `[0.04, 0.96]` safeBox + `centredOK` bypass,
    /// and `.turned45`/`.kneeLift` standing-foot rule (§2.2, §3.5, §7.1).
    public static func evaluateFraming(
        _ sample: CalibrationPoseSample,
        forPose pose: PoseKind = .rest,
        cameraMode: CameraMode = .frontSelfView,
        calibrationTier: CalibrationResumeTier = .tier2FullCalibration,
        dancerDistanceM: Double? = nil,
        measuredHeightM: Double? = nil,
        storedHeightM: Double? = nil,
        cameraHeightM: Double? = nil,
        wingspanM: Double? = nil,
        verticalFoVDeg: Double? = nil,
        horizontalFoVDeg: Double? = nil,
        passing: Bool = false,
        relaxed: Bool = false,
        warmupElapsedS: Double = 0.0,
        tuning u: CalibrationTuning = .defaults
    ) -> FramingEvaluation {
        let pts = sample.landmarks
        var visDelta = 0.0
        if relaxed { visDelta = max(visDelta, u.relaxVisibilityDelta) }
        if passing { visDelta = max(visDelta, u.framingStayVisibilityDelta) }
        let coreFloor = u.coreMinVisibility - visDelta
        let footFloor = u.footMinVisibility - visDelta

        let shoulderVis = min(visibility(pts, "leftShoulder"), visibility(pts, "rightShoulder"))
        let presence = shoulderVis >= u.presenceMinVisibility

        let coreVis = coreJoints.map { visibility(pts, $0) }.min() ?? 0.0
        let legVis: Double = {
            if pose == .turned45 || pose == .kneeLift {
                // During oblique turns or single-leg knee lifts, require knees + at least standing ankle >= coreFloor.
                let kneesMin = min(visibility(pts, "leftKnee"), visibility(pts, "rightKnee"))
                let bestAnkle = max(visibility(pts, "leftAnkle"), visibility(pts, "rightAnkle"))
                return min(kneesMin, bestAnkle)
            }
            return legJoints.map { visibility(pts, $0) }.min() ?? 0.0
        }()

        let feetOK: Bool = {
            if pose == .turned45 || pose == .kneeLift {
                let leftFootMin = min(visibility(pts, "leftHeel"), visibility(pts, "leftFootIndex"))
                let rightFootMin = min(visibility(pts, "rightHeel"), visibility(pts, "rightFootIndex"))
                return max(leftFootMin, rightFootMin) >= footFloor
            }
            let footVis = footJoints.map { visibility(pts, $0) }.min() ?? 0.0
            return footVis >= footFloor
        }()

        let coreOK: Bool = {
            if pose == .turned45 || pose == .kneeLift {
                let upperCore = ["nose", "leftShoulder", "rightShoulder", "leftHip", "rightHip"]
                    .map { visibility(pts, $0) }.min() ?? 0.0
                return min(upperCore, legVis) >= coreFloor
            }
            return coreVis >= coreFloor
        }()

        let noseVis = visibility(pts, "nose")
        let headOK = noseVis >= coreFloor

        let boxPoints = (coreJoints + footJoints).compactMap { landmark(pts, $0) }
        let minX = boxPoints.map(\.x).min()
        let maxX = boxPoints.map(\.x).max()
        let safeMinX = (pose == .stepLeft || pose == .stepRight) ? 0.04 : u.safeBoxMinX
        let safeMaxX = (pose == .stepLeft || pose == .stepRight) ? 0.96 : u.safeBoxMaxX
        let leftOut = (minX ?? 0.0) < safeMinX
        let rightOut = (maxX ?? 1.0) > safeMaxX
        let safeOK = !leftOut && !rightOut

        let maxFootY = footJoints.compactMap { landmark(pts, $0)?.y }.max()
        let noseY = landmark(pts, "nose")?.y
        let span: Double? = {
            guard let f = maxFootY, let n = noseY else { return nil }
            return f - n
        }()
        let feetInFrame = (maxFootY ?? 1.0) <= u.maxFootY
        let headroom = (noseY ?? 0.0) >= u.minNoseY

        let distEval = evaluateDistance(
            cameraMode: cameraMode,
            dancerDistanceM: dancerDistanceM,
            measuredHeightM: measuredHeightM,
            storedHeightM: storedHeightM,
            cameraHeightM: cameraHeightM,
            wingspanM: wingspanM,
            verticalFoVDeg: verticalFoVDeg,
            horizontalFoVDeg: horizontalFoVDeg,
            passing: passing,
            relaxed: relaxed,
            warmupElapsedS: warmupElapsedS,
            tuning: u
        )

        let spanBounds = effectiveSpanBounds(
            cameraMode: cameraMode,
            calibrationTier: calibrationTier,
            dancerDistanceM: dancerDistanceM,
            measuredHeightM: measuredHeightM,
            storedHeightM: storedHeightM,
            cameraHeightM: cameraHeightM,
            wingspanM: wingspanM,
            verticalFoVDeg: verticalFoVDeg,
            horizontalFoVDeg: horizontalFoVDeg,
            passing: passing,
            relaxed: relaxed,
            tuning: u
        )
        let spanOK = span.map { $0 >= spanBounds.spanMinUsed && $0 <= spanBounds.spanMaxUsed } ?? false

        let hipX = hipCenterX2D(pts)
        let useTightRestCentring = (pose == .rest && calibrationTier == .tier2FullCalibration)
        let hipMinUsed = useTightRestCentring ? u.restHipCenterMinX : u.hipCenterMinX
        let hipMaxUsed = useTightRestCentring ? u.restHipCenterMaxX : u.hipCenterMaxX
        let bypassCentring = (pose == .stepLeft || pose == .stepRight)
        let centredOK = bypassCentring
            ? (hipX != nil)
            : (hipX.map { $0 >= hipMinUsed && $0 <= hipMaxUsed } ?? false)

        let isLiDARDistanceCoupled = (cameraMode == .rearLiDAR && dancerDistanceM != nil)

        let cue: PoseCue
        if !presence {
            cue = .stepIn
        } else if distEval.isActive && !distEval.distanceOK {
            // Distance cue precedence (§3.5): emit dynamic metric cue (or .none during <0.25 s warm-up) before 2D span.
            cue = distEval.cue
        } else if !feetOK || legVis < coreFloor {
            cue = .stepBackShowFeet
        } else if !headOK {
            cue = .showHead
        } else if !coreOK {
            cue = .stepBack
        } else if !feetInFrame {
            cue = .stepBackShowFeet
        } else if !headroom {
            cue = .stepBack
        } else if let s = span, s > spanBounds.spanMaxUsed {
            cue = .stepBack
        } else if !spanOK {
            // In Mode A (rearLiDAR with valid distance), never emit a conflicting .stepCloser cue (§3.5).
            cue = isLiDARDistanceCoupled ? .stepBackShowFeet : .stepCloser
        } else if leftOut && rightOut {
            cue = (pose == .stepLeft || pose == .stepRight) ? .stepBackLateralRoom : .stepBack
        } else if leftOut {
            cue = (pose == .stepLeft || pose == .stepRight) ? .stepBackLateralRoom : .moveLeft
        } else if rightOut {
            cue = (pose == .stepLeft || pose == .stepRight) ? .stepBackLateralRoom : .moveRight
        } else if !bypassCentring, let h = hipX, h < hipMinUsed {
            cue = .moveLeft
        } else if !centredOK {
            cue = .moveRight
        } else {
            cue = .none
        }

        let allPass = presence
            && distEval.distanceOK
            && coreOK
            && feetOK
            && legVis >= coreFloor
            && headOK
            && safeOK
            && feetInFrame
            && headroom
            && spanOK
            && centredOK

        return FramingEvaluation(
            presence: presence,
            coreVisibleOK: coreOK,
            feetVisibleOK: feetOK,
            headVisibleOK: headOK,
            safeBoxOK: safeOK,
            feetInFrameOK: feetInFrame,
            headroomOK: headroom,
            distanceEvaluation: distEval,
            span: span,
            spanBounds: spanBounds,
            spanOK: spanOK,
            hipCenterX: hipX,
            hipCenterMinUsed: hipMinUsed,
            hipCenterMaxUsed: hipMaxUsed,
            centredOK: centredOK,
            coreFloorUsed: coreFloor,
            footFloorUsed: footFloor,
            minX: minX,
            maxX: maxX,
            noseY: noseY,
            maxFootY: maxFootY,
            passes: allPass,
            cue: cue
        )
    }

    /// Evaluation result for Pose 1 (`.rest`, `stepIndex 2`, §2.2).
    public struct RestEvaluation: Equatable, Sendable {
        public var framing: FramingEvaluation
        public var armsRelaxedOK: Bool
        public var stillOK: Bool
        public var standingKneeFlexDeg: Double?
        public var trunkLeanBaselineDeg: Double?
        public var restHipHeightNorm: Double?
        public var passes: Bool
        public var cue: PoseCue
    }

    /// Evaluates Pose 1 (`.rest`, §2.2): full-body framing + FoV/distance-coupled span + Tier-2 `[0.40, 0.60]`
    /// centring + LiDAR distance check + arms relaxed by sides (`lw.y, rw.y > hipY - 0.05*span`, `|wrist.x - hip.x| < 0.22`).
    public static func evaluateRest(
        _ sample: CalibrationPoseSample,
        cameraMode: CameraMode = .frontSelfView,
        calibrationTier: CalibrationResumeTier = .tier2FullCalibration,
        dancerDistanceM: Double? = nil,
        measuredHeightM: Double? = nil,
        storedHeightM: Double? = nil,
        cameraHeightM: Double? = nil,
        wingspanM: Double? = nil,
        verticalFoVDeg: Double? = nil,
        horizontalFoVDeg: Double? = nil,
        cameraGravity: CalibrationVector3 = CalibrationVector3(x: 0, y: -1, z: 0),
        passing: Bool = false,
        relaxed: Bool = false,
        warmupElapsedS: Double = 0.0,
        bodyMotion: Double? = nil,
        isLatched: Bool = false,
        tuning u: CalibrationTuning = .defaults
    ) -> RestEvaluation {
        let framing = evaluateFraming(
            sample,
            forPose: .rest,
            cameraMode: cameraMode,
            calibrationTier: calibrationTier,
            dancerDistanceM: dancerDistanceM,
            measuredHeightM: measuredHeightM,
            storedHeightM: storedHeightM,
            cameraHeightM: cameraHeightM,
            wingspanM: wingspanM,
            verticalFoVDeg: verticalFoVDeg,
            horizontalFoVDeg: horizontalFoVDeg,
            passing: passing,
            relaxed: relaxed,
            warmupElapsedS: warmupElapsedS,
            tuning: u
        )

        let pts = sample.landmarks
        let armsRelaxedOK: Bool = {
            guard let lh = landmark(pts, "leftHip"),
                  let rh = landmark(pts, "rightHip"),
                  let lw = landmark(pts, "leftWrist"),
                  let rw = landmark(pts, "rightWrist"),
                  min(lw.visibility, rw.visibility) >= u.tPoseArmMinVisibility else {
                return false
            }
            let hipY = 0.5 * (lh.y + rh.y)
            let spanVal = max(0.05, framing.span ?? 0.5)
            let minWristY = hipY - 0.05 * spanVal
            let wristsLow = lw.y > minWristY && rw.y > minWristY
            let wristsCloseToHips = abs(lw.x - lh.x) < 0.22 && abs(rw.x - rh.x) < 0.22
            return wristsLow && wristsCloseToHips
        }()

        let motionLimit = isLatched ? PoseKind.rest.motionStayMax(tuning: u) : PoseKind.rest.motionEnterMax(tuning: u)
        let stillOK = bodyMotion.map { $0 <= motionLimit } ?? true

        var standingKneeFlexDeg: Double?
        var trunkLeanBaselineDeg: Double?
        var restHipHeightNorm: Double?
        if let frame = sample.frame {
            let features = extractPostureMetrics(frame: frame, cameraGravity: cameraGravity)
            standingKneeFlexDeg = features.meanKneeFlexDeg
            trunkLeanBaselineDeg = features.trunkLeanDeg
            restHipHeightNorm = features.hipHeightNorm
        }

        let passes = framing.passes && armsRelaxedOK && stillOK
        let cue: PoseCue
        if !framing.passes {
            cue = framing.cue
        } else if !armsRelaxedOK {
            cue = .relaxArms
        } else if !stillOK {
            cue = .holdStill
        } else {
            cue = .none
        }

        return RestEvaluation(
            framing: framing,
            armsRelaxedOK: armsRelaxedOK,
            stillOK: stillOK,
            standingKneeFlexDeg: standingKneeFlexDeg,
            trunkLeanBaselineDeg: trunkLeanBaselineDeg,
            restHipHeightNorm: restHipHeightNorm,
            passes: passes,
            cue: cue
        )
    }

    // MARK: - 3D Posture Metrics Helper (mirrors GrooveScoringEngine.extractFrameFeatures)

    struct PostureMetrics: Equatable, Sendable {
        var leftKneeFlexDeg: Double?
        var rightKneeFlexDeg: Double?
        var meanKneeFlexDeg: Double?
        var trunkLeanDeg: Double?
        var legScale: Double?
        var hipHeightNorm: Double?
        var hipXNorm: Double?
        var straightLegHipHeightNorm: Double?
    }

    static func extractPostureMetrics(
        frame: GrooveScoringEngine.RawPoseFrame,
        cameraGravity: CalibrationVector3
    ) -> PostureMetrics {
        let j = gravityAlignedJoints(frame, cameraGravity: cameraGravity)
        var out = PostureMetrics()

        if let root = j["root"], let cs = j["centerShoulder"] {
            out.trunkLeanDeg = angleBetween3DDeg(cs - root, Vec3(0.0, 1.0, 0.0))
        }

        guard let lh = j["leftHip"], let lk = j["leftKnee"], let la = j["leftAnkle"],
              let rh = j["rightHip"], let rk = j["rightKnee"], let ra = j["rightAnkle"] else {
            return out
        }

        let lThigh = lk - lh
        let lShin = la - lk
        let rThigh = rk - rh
        let rShin = ra - rk
        let lFlex = angleBetween3DDeg(lThigh, lShin)
        let rFlex = angleBetween3DDeg(rThigh, rShin)
        out.leftKneeFlexDeg = lFlex
        out.rightKneeFlexDeg = rFlex
        out.meanKneeFlexDeg = 0.5 * (lFlex + rFlex)

        let legScale = max(0.4, 0.5 * ((lThigh.norm + lShin.norm) + (rThigh.norm + rShin.norm)))
        out.legScale = legScale

        let root = j["root"] ?? Vec3(0, 0, 0)
        let baseY: Double
        if let lheel = j["leftHeel"], j["leftFootIndex"] != nil,
           let rheel = j["rightHeel"], j["rightFootIndex"] != nil {
            baseY = 0.5 * (lheel.y + rheel.y)
        } else {
            baseY = 0.5 * (la.y + ra.y) - 0.05
        }
        out.hipHeightNorm = (root.y - baseY) / legScale
        out.hipXNorm = root.x / legScale

        let meanAnkleY = 0.5 * (la.y + ra.y)
        let footDropBelowAnkle = meanAnkleY - baseY
        out.straightLegHipHeightNorm = 1.0 + footDropBelowAnkle / legScale
        return out
    }

    /// Computes interior elbow angles `(leftDeg, rightDeg)` using gravity-aligned 3D joints when all 6 arm
    /// joints are present in `sample.frame`, falling back to 2D normalized landmarks otherwise.
    static func interiorElbowAnglesDeg(
        pts: [CalibrationLandmark],
        joints3D: [String: Vec3]
    ) -> (left: Double, right: Double)? {
        if let ls3 = joints3D["leftShoulder"], let le3 = joints3D["leftElbow"], let lw3 = joints3D["leftWrist"],
           let rs3 = joints3D["rightShoulder"], let re3 = joints3D["rightElbow"], let rw3 = joints3D["rightWrist"] {
            return (
                angleBetween3DDeg(ls3 - le3, lw3 - le3),
                angleBetween3DDeg(rs3 - re3, rw3 - re3)
            )
        }
        guard let ls = landmark(pts, "leftShoulder"), let le = landmark(pts, "leftElbow"), let lw = landmark(pts, "leftWrist"),
              let rs = landmark(pts, "rightShoulder"), let re = landmark(pts, "rightElbow"), let rw = landmark(pts, "rightWrist") else {
            return nil
        }
        return (angle2DDeg(ls, le, lw), angle2DDeg(rs, re, rw))
    }

    /// Computes torso-frame upper-arm elevation angles `(leftDeg, rightDeg)` (`0°` = hanging down along `-e2`,
    /// `90°` = horizontal T-pose, `~170–180°` = straight overhead; §2.2 Pose 3, §6.1, §8.2).
    static func shoulderElevationAnglesDeg(
        pts: [CalibrationLandmark],
        joints3D: [String: Vec3]
    ) -> (left: Double, right: Double)? {
        if let lh = joints3D["leftHip"], let rh = joints3D["rightHip"],
           let root = joints3D["root"], let cs = joints3D["centerShoulder"],
           let ls = joints3D["leftShoulder"], let le = joints3D["leftElbow"],
           let rs = joints3D["rightShoulder"], let re = joints3D["rightElbow"] {
            let e1 = (rh - lh).normalized
            let up = cs - root
            let proj = Vec3.dot(up, e1)
            let e2 = (up - e1 * proj).normalized
            if e1.norm >= 0.5, e2.norm >= 0.5 {
                let downAxis = e2 * -1.0
                return (
                    angleBetween3DDeg(le - ls, downAxis),
                    angleBetween3DDeg(re - rs, downAxis)
                )
            }
        }
        guard let ls = landmark(pts, "leftShoulder"), let le = landmark(pts, "leftElbow"),
              let rs = landmark(pts, "rightShoulder"), let re = landmark(pts, "rightElbow") else {
            return nil
        }
        // In 2D normalized portrait coords (+y down), downward is (0, +1).
        func elev2D(_ s: CalibrationLandmark, _ e: CalibrationLandmark) -> Double {
            let vx = e.x - s.x
            let vy = e.y - s.y
            let n = hypot(vx, vy)
            guard n > 1e-9 else { return 0.0 }
            return acos(clamp(vy / n, -1.0, 1.0)) * 180.0 / .pi
        }
        return (elev2D(ls, le), elev2D(rs, re))
    }

    // MARK: - Pose 2: `.tpose` Evaluator (§2.2 Pose 2)

    /// Evaluation result for Pose 2 (`.tpose`, `stepIndex 4`, §2.2).
    public struct TPoseEvaluation: Equatable, Sendable {
        public var tPoseScore: CalibrationGate.TPoseScore
        public var wristsInBoundsOK: Bool
        public var hipCenterX: Double?
        public var stillOK: Bool
        public var passes: Bool
        public var cue: PoseCue
    }

    /// Evaluates Pose 2 (`.tpose`, §2.2): delegates T-pose geometry to `CalibrationGate.tPoseScore`, enforces
    /// wrists within `x ∈ [0.03, 0.97]`, and disambiguates `.moveLeft`/`.moveRight` (`|hipCenterX - 0.50| > 0.08`)
    /// vs `.stepBack` when wrists clip the frame edges.
    public static func evaluateTPose(
        _ sample: CalibrationPoseSample,
        bodyMotion: Double? = nil,
        isLatched: Bool = false,
        tuning u: CalibrationTuning = .defaults
    ) -> TPoseEvaluation {
        let pts = sample.landmarks
        let score = CalibrationGate.tPoseScore(sample, tuning: u)
        let hipX = hipCenterX2D(pts)

        let lw = landmark(pts, "leftWrist")
        let rw = landmark(pts, "rightWrist")
        let le = landmark(pts, "leftElbow")
        let re = landmark(pts, "rightElbow")

        let wristsVisible = (lw?.visibility ?? 0.0) >= u.tPoseArmMinVisibility
            && (rw?.visibility ?? 0.0) >= u.tPoseArmMinVisibility
        let leftClipped: Bool = {
            guard let w = lw else { return false }
            let active = w.visibility >= u.tPoseArmMinVisibility || (le?.visibility ?? 0.0) >= u.tPoseArmMinVisibility
            return active && (w.x < 0.03 || w.x > 0.97)
        }()
        let rightClipped: Bool = {
            guard let w = rw else { return false }
            let active = w.visibility >= u.tPoseArmMinVisibility || (re?.visibility ?? 0.0) >= u.tPoseArmMinVisibility
            return active && (w.x < 0.03 || w.x > 0.97)
        }()
        let anyWristClipped = leftClipped || rightClipped
        let wristsInBoundsOK = wristsVisible && !anyWristClipped

        let motionLimit = isLatched ? PoseKind.tpose.motionStayMax(tuning: u) : PoseKind.tpose.motionEnterMax(tuning: u)
        let stillOK = bodyMotion.map { $0 <= motionLimit } ?? true

        let passes = score.passes && wristsInBoundsOK && stillOK
        let cue: PoseCue
        if anyWristClipped {
            if let hx = hipX, abs(hx - 0.50) > 0.08 {
                cue = hx < 0.50 ? .moveLeft : .moveRight
            } else {
                cue = .stepBack
            }
        } else if !score.passes || !wristsInBoundsOK {
            cue = .armsOutT
        } else if !stillOK {
            cue = .holdStill
        } else {
            cue = .none
        }

        return TPoseEvaluation(
            tPoseScore: score,
            wristsInBoundsOK: wristsInBoundsOK,
            hipCenterX: hipX,
            stillOK: stillOK,
            passes: passes,
            cue: cue
        )
    }

    // MARK: - Pose 3: `.overhead` Evaluator (§2.2 Pose 3)

    /// Evaluation result for Pose 3 (`.overhead`, `stepIndex 5`, §2.2).
    public struct OverheadEvaluation: Equatable, Sendable {
        public var wristsAboveNoseOK: Bool
        public var topMarginOK: Bool
        public var wristsVisibleOK: Bool
        public var elbowsExtendedOK: Bool
        public var leftElbowDeg: Double?
        public var rightElbowDeg: Double?
        public var overheadHeadroomMinY: Double?
        public var maxShoulderElevationDeg: Double?
        public var stillOK: Bool
        public var passes: Bool
        public var cue: PoseCue
    }

    /// Evaluates Pose 3 (`.overhead`, §2.2): both wrists above nose (`wrist.y < nose.y - 0.05 * span`),
    /// unclipped at top edge (`min(lw.y, rw.y) >= 0.02`, wrist visibility `>= 0.45`), and interior elbow
    /// extension `>= 135°`.
    public static func evaluateOverhead(
        _ sample: CalibrationPoseSample,
        cameraGravity: CalibrationVector3 = CalibrationVector3(x: 0, y: -1, z: 0),
        bodyMotion: Double? = nil,
        isLatched: Bool = false,
        tuning u: CalibrationTuning = .defaults
    ) -> OverheadEvaluation {
        let pts = sample.landmarks
        let j3D = gravityAlignedJoints(sample.frame, cameraGravity: cameraGravity)

        let nose = landmark(pts, "nose")
        let lw = landmark(pts, "leftWrist")
        let rw = landmark(pts, "rightWrist")
        let ls = landmark(pts, "leftShoulder")
        let rs = landmark(pts, "rightShoulder")
        let le = landmark(pts, "leftElbow")
        let re = landmark(pts, "rightElbow")

        let spanVal = max(0.05, span2D(pts)?.span ?? 0.5)
        let headroomMinY: Double? = {
            guard let l = lw, let r = rw else { return nil }
            return min(l.y, r.y)
        }()

        let wristsVisibleOK = (lw?.visibility ?? 0.0) >= 0.45 && (rw?.visibility ?? 0.0) >= 0.45
        let topMarginOK = headroomMinY.map { $0 >= u.overheadMinTopMarginY } ?? false
        let wristsAboveNoseOK: Bool = {
            guard let n = nose, let l = lw, let r = rw else { return false }
            let thresholdY = n.y - u.overheadMinWristAboveNose * spanVal
            return l.y < thresholdY && r.y < thresholdY
        }()

        let elbows = interiorElbowAnglesDeg(pts: pts, joints3D: j3D)
        let elbowsExtendedOK = elbows.map {
            min($0.left, $0.right) >= u.overheadMinElbowDeg
        } ?? false

        let shoulderElev = shoulderElevationAnglesDeg(pts: pts, joints3D: j3D)
        let maxShoulderElevDeg = shoulderElev.map { 0.5 * ($0.left + $0.right) }

        let motionLimit = isLatched ? PoseKind.overhead.motionStayMax(tuning: u) : PoseKind.overhead.motionEnterMax(tuning: u)
        let stillOK = bodyMotion.map { $0 <= motionLimit } ?? true

        let armsAttemptingOverhead: Bool = {
            guard let ls, let rs else { return false }
            let elbowsUp = (le.map { $0.y < ls.y } ?? false) || (re.map { $0.y < rs.y } ?? false)
            let wristsUp = (lw.map { $0.y < (nose?.y ?? ls.y) } ?? false) || (rw.map { $0.y < (nose?.y ?? rs.y) } ?? false)
            return elbowsUp || wristsUp
        }()

        let passes = wristsAboveNoseOK && topMarginOK && wristsVisibleOK && elbowsExtendedOK && stillOK
        let cue: PoseCue
        if (!topMarginOK && wristsAboveNoseOK) || (armsAttemptingOverhead && (!topMarginOK || !wristsVisibleOK)) {
            cue = .stepBackHeadroom
        } else if !(wristsAboveNoseOK && topMarginOK && wristsVisibleOK && elbowsExtendedOK) {
            cue = .reachOverhead
        } else if !stillOK {
            cue = .holdStill
        } else {
            cue = .none
        }

        return OverheadEvaluation(
            wristsAboveNoseOK: wristsAboveNoseOK,
            topMarginOK: topMarginOK,
            wristsVisibleOK: wristsVisibleOK,
            elbowsExtendedOK: elbowsExtendedOK,
            leftElbowDeg: elbows?.left,
            rightElbowDeg: elbows?.right,
            overheadHeadroomMinY: headroomMinY,
            maxShoulderElevationDeg: maxShoulderElevDeg,
            stillOK: stillOK,
            passes: passes,
            cue: cue
        )
    }

    // MARK: - Pose 4: `.asymLR` Evaluator & Swap Detector (§2.2 Pose 4)

    /// Evaluation result for Pose 4 (`.asymLR`, `stepIndex 6`, §2.2).
    public struct AsymLREvaluation: Equatable, Sendable {
        public var leftOverheadOK: Bool
        public var rightHorizontalOK: Bool
        /// True on a single frame whenever anatomical `rightWrist` is overhead and `leftWrist` is horizontal.
        public var isReversedPose: Bool
        /// True when reversed sides are detected (immediately in single-sample stateless mode, or once held
        /// `>= 0.35 s` when `reversedDurationS` is supplied; §2.2 Pose 4).
        public var lrSwapped: Bool
        public var armSymmetryRatio: Double?
        public var stillOK: Bool
        public var passes: Bool
        public var cue: PoseCue
    }

    /// Stateful helper tracking sustained L/R swap (`>= 0.35 s`) across Pose 4 samples and clearing `lrSwapped`
    /// once `.asymLR` passes cleanly (§2.2 Pose 4).
    public struct AsymLRSwapTracker: Equatable, Sendable {
        public private(set) var reversedSince: Double?
        public private(set) var lrSwapped: Bool = false

        public init() {}

        public mutating func reset() {
            reversedSince = nil
            lrSwapped = false
        }

        public mutating func evaluate(
            timestamp: Double,
            sample: CalibrationPoseSample,
            cameraGravity: CalibrationVector3 = CalibrationVector3(x: 0, y: -1, z: 0),
            bodyMotion: Double? = nil,
            isLatched: Bool = false,
            tuning u: CalibrationTuning = .defaults
        ) -> AsymLREvaluation {
            let probe = CalibrationPoseScorers.evaluateAsymLR(
                sample,
                cameraGravity: cameraGravity,
                reversedDurationS: 0.0,
                bodyMotion: bodyMotion,
                isLatched: isLatched,
                tuning: u
            )
            let reversedDuration: Double
            if probe.isReversedPose {
                let since = reversedSince ?? timestamp
                reversedSince = since
                reversedDuration = max(0.0, timestamp - since)
                if reversedDuration >= u.dropoutToleranceS {
                    lrSwapped = true
                }
            } else {
                reversedSince = nil
                reversedDuration = 0.0
                if probe.passes {
                    lrSwapped = false
                }
            }

            var result = CalibrationPoseScorers.evaluateAsymLR(
                sample,
                cameraGravity: cameraGravity,
                reversedDurationS: reversedDuration,
                bodyMotion: bodyMotion,
                isLatched: isLatched,
                tuning: u
            )
            if lrSwapped && !result.passes {
                result.lrSwapped = true
                if probe.isReversedPose {
                    result.cue = .swapArmsLR
                }
            }
            return result
        }
    }

    /// Evaluates Pose 4 (`.asymLR`, §2.2): anatomical `leftWrist` overhead (`lw.y < nose.y - 0.03*span`,
    /// left elbow `>= 130°`) AND `rightWrist` horizontal (`|rw.y - rs.y| / torso <= 0.35`,
    /// `|rw.x - rs.x| / shoulder >= 0.80`, right elbow `>= 130°`), plus swapped-side (`lrSwapped`) detection.
    public static func evaluateAsymLR(
        _ sample: CalibrationPoseSample,
        cameraGravity: CalibrationVector3 = CalibrationVector3(x: 0, y: -1, z: 0),
        reversedDurationS: Double? = nil,
        bodyMotion: Double? = nil,
        isLatched: Bool = false,
        tuning u: CalibrationTuning = .defaults
    ) -> AsymLREvaluation {
        let pts = sample.landmarks
        let j3D = gravityAlignedJoints(sample.frame, cameraGravity: cameraGravity)

        guard let nose = landmark(pts, "nose"),
              let ls = landmark(pts, "leftShoulder"),
              let rs = landmark(pts, "rightShoulder"),
              let le = landmark(pts, "leftElbow"),
              let re = landmark(pts, "rightElbow"),
              let lw = landmark(pts, "leftWrist"),
              let rw = landmark(pts, "rightWrist"),
              let scales = torsoScale2D(pts),
              let elbows = interiorElbowAnglesDeg(pts: pts, joints3D: j3D) else {
            return AsymLREvaluation(
                leftOverheadOK: false,
                rightHorizontalOK: false,
                isReversedPose: false,
                lrSwapped: false,
                armSymmetryRatio: nil,
                stillOK: bodyMotion.map { $0 <= PoseKind.asymLR.motionEnterMax(tuning: u) } ?? true,
                passes: false,
                cue: .asymPose
            )
        }

        let spanVal = max(0.05, span2D(pts)?.span ?? 0.5)
        let torso = max(scales.torso, scales.shoulder * 0.6, 1e-6)
        let shoulder = scales.shoulder
        let minArmVis = u.tPoseArmMinVisibility

        let leftVisOK = min(ls.visibility, le.visibility, lw.visibility) >= minArmVis
        let rightVisOK = min(rs.visibility, re.visibility, rw.visibility) >= minArmVis

        let overheadThresholdY = nose.y - 0.03 * spanVal
        let leftOverheadOK = leftVisOK && lw.y < overheadThresholdY && elbows.left >= 130.0

        // Outward check: wrist extends away from opposite shoulder on its own side.
        let rightOutward = (rs.x - ls.x) * (rw.x - rs.x) >= 0.0
        let rightHorizontalOK = rightVisOK
            && rightOutward
            && (abs(rw.y - rs.y) / torso) <= 0.35
            && (abs(rw.x - rs.x) / shoulder) >= u.asymMinSideReachShoulders
            && elbows.right >= 130.0

        // Reversed pose: rightWrist overhead AND leftWrist horizontal.
        let rightOverheadReversed = rightVisOK && rw.y < overheadThresholdY && elbows.right >= 130.0
        let leftOutward = (ls.x - rs.x) * (lw.x - ls.x) >= 0.0
        let leftHorizontalReversed = leftVisOK
            && leftOutward
            && (abs(lw.y - ls.y) / torso) <= 0.35
            && (abs(lw.x - ls.x) / shoulder) >= u.asymMinSideReachShoulders
            && elbows.left >= 130.0
        let isReversedPose = rightOverheadReversed && leftHorizontalReversed

        let lrSwapped: Bool
        if let dur = reversedDurationS {
            lrSwapped = isReversedPose && dur >= u.dropoutToleranceS
        } else {
            lrSwapped = isReversedPose
        }

        let armSymmetryRatio: Double? = {
            if let cs3 = j3D["centerShoulder"],
               let ls3 = j3D["leftShoulder"], let le3 = j3D["leftElbow"], let lw3 = j3D["leftWrist"],
               let rs3 = j3D["rightShoulder"], let re3 = j3D["rightElbow"], let rw3 = j3D["rightWrist"] {
                let leftM = (ls3 - cs3).norm + (le3 - ls3).norm + (lw3 - le3).norm
                let rightM = (rs3 - cs3).norm + (re3 - rs3).norm + (rw3 - re3).norm
                if rightM > 1e-6 { return leftM / rightM }
            }
            let left2D = hypot(le.x - ls.x, le.y - ls.y) + hypot(lw.x - le.x, lw.y - le.y)
            let right2D = hypot(re.x - rs.x, re.y - rs.y) + hypot(rw.x - re.x, rw.y - re.y)
            return right2D > 1e-6 ? (left2D / right2D) : nil
        }()

        let motionLimit = isLatched ? PoseKind.asymLR.motionStayMax(tuning: u) : PoseKind.asymLR.motionEnterMax(tuning: u)
        let stillOK = bodyMotion.map { $0 <= motionLimit } ?? true

        let passes = leftOverheadOK && rightHorizontalOK && stillOK
        let cue: PoseCue
        if lrSwapped {
            cue = .swapArmsLR
        } else if !(leftOverheadOK && rightHorizontalOK) {
            cue = .asymPose
        } else if !stillOK {
            cue = .holdStill
        } else {
            cue = .none
        }

        return AsymLREvaluation(
            leftOverheadOK: leftOverheadOK,
            rightHorizontalOK: rightHorizontalOK,
            isReversedPose: isReversedPose,
            lrSwapped: lrSwapped,
            armSymmetryRatio: armSymmetryRatio,
            stillOK: stillOK,
            passes: passes,
            cue: cue
        )
    }

    // MARK: - Pose 5: `.armsForward` Evaluator (§2.2 Pose 5)

    /// Evaluation result for Pose 5 (`.armsForward`, `stepIndex 7`, §2.2).
    public struct ArmsForwardEvaluation: Equatable, Sendable {
        public var canonicalForwardOK: Bool
        public var wristsAtShoulderHeightOK: Bool
        public var lidarDeltaZOK: Bool
        public var leftCanonicalDeltaZM: Double?
        public var rightCanonicalDeltaZM: Double?
        public var zDepthScaleRatio: Double?
        public var stillOK: Bool
        public var passes: Bool
        public var cue: PoseCue
    }

    /// Evaluates Pose 5 (`.armsForward`, §2.2): canonical 3D wrists forward of shoulders (`lw3D.z - ls3D.z >= 0.25 m`,
    /// `rw3D.z - rs3D.z >= 0.25 m`), 2D wrists near shoulder height (`|w.y - s.y| / torso <= 0.40`), and when
    /// `rearLiDAR` is active, `shoulderToWristDeltaZM >= 0.25 m`.
    public static func evaluateArmsForward(
        _ sample: CalibrationPoseSample,
        cameraMode: CameraMode = .frontSelfView,
        shoulderToWristDeltaZM: Double? = nil,
        cameraGravity: CalibrationVector3 = CalibrationVector3(x: 0, y: -1, z: 0),
        bodyMotion: Double? = nil,
        isLatched: Bool = false,
        tuning u: CalibrationTuning = .defaults
    ) -> ArmsForwardEvaluation {
        let pts = sample.landmarks
        let j3D = gravityAlignedJoints(sample.frame, cameraGravity: cameraGravity)

        let wristsAtShoulderHeightOK: Bool = {
            guard let ls = landmark(pts, "leftShoulder"),
                  let rs = landmark(pts, "rightShoulder"),
                  let lw = landmark(pts, "leftWrist"),
                  let rw = landmark(pts, "rightWrist"),
                  let scales = torsoScale2D(pts),
                  min(ls.visibility, rs.visibility, lw.visibility, rw.visibility) >= u.tPoseArmMinVisibility else {
                return false
            }
            let torso = max(scales.torso, scales.shoulder * 0.6, 1e-6)
            return (abs(lw.y - ls.y) / torso) <= 0.40 && (abs(rw.y - rs.y) / torso) <= 0.40
        }()

        let leftDZ: Double? = {
            guard let ls3 = j3D["leftShoulder"], let lw3 = j3D["leftWrist"] else { return nil }
            return lw3.z - ls3.z
        }()
        let rightDZ: Double? = {
            guard let rs3 = j3D["rightShoulder"], let rw3 = j3D["rightWrist"] else { return nil }
            return rw3.z - rs3.z
        }()
        let canonicalForwardOK: Bool = {
            guard let l = leftDZ, let r = rightDZ else { return false }
            return l >= u.forwardMinDeltaZM && r >= u.forwardMinDeltaZM
        }()

        let lidarDeltaZOK: Bool = {
            guard cameraMode == .rearLiDAR else { return true }
            guard let dz = shoulderToWristDeltaZM, dz.isFinite else { return false }
            return dz >= u.forwardMinDeltaZM
        }()

        let zDepthScaleRatio: Double? = {
            guard let lidarDZ = shoulderToWristDeltaZM, lidarDZ.isFinite, lidarDZ > 0,
                  let l = leftDZ, let r = rightDZ else {
                return nil
            }
            let meanCanonical = 0.5 * (l + r)
            guard meanCanonical > 1e-6 else { return nil }
            return lidarDZ / meanCanonical
        }()

        let motionLimit = isLatched ? PoseKind.armsForward.motionStayMax(tuning: u) : PoseKind.armsForward.motionEnterMax(tuning: u)
        let stillOK = bodyMotion.map { $0 <= motionLimit } ?? true

        let passes = canonicalForwardOK && wristsAtShoulderHeightOK && lidarDeltaZOK && stillOK
        let cue: PoseCue
        if !(canonicalForwardOK && wristsAtShoulderHeightOK && lidarDeltaZOK) {
            cue = .armsForward
        } else if !stillOK {
            cue = .holdStill
        } else {
            cue = .none
        }

        return ArmsForwardEvaluation(
            canonicalForwardOK: canonicalForwardOK,
            wristsAtShoulderHeightOK: wristsAtShoulderHeightOK,
            lidarDeltaZOK: lidarDeltaZOK,
            leftCanonicalDeltaZM: leftDZ,
            rightCanonicalDeltaZM: rightDZ,
            zDepthScaleRatio: zDepthScaleRatio,
            stillOK: stillOK,
            passes: passes,
            cue: cue
        )
    }

    // MARK: - Pose 6: `.plie` Evaluator (§2.2 Pose 6)

    /// Evaluation result for Pose 6 (`.plie`, `stepIndex 8`, §2.2).
    public struct PlieEvaluation: Equatable, Sendable {
        public var kneeFlexOK: Bool
        public var hipDropOK: Bool
        public var armsOutOK: Bool
        public var feetVisibleOK: Bool
        public var meanKneeFlexDeg: Double?
        public var hipHeightNorm: Double?
        public var plieHipDropNorm: Double?
        public var tPoseSY: Double
        public var stillOK: Bool
        public var passes: Bool
        public var cue: PoseCue
    }

    /// Evaluates Pose 6 (`.plie`, §2.2): exterior `mean_knee_flex >= 22°` (and `>= standingKneeFlexDeg + 15°`),
    /// `hip_height_norm` drop `>= 0.04` below `.rest`, arms out (`sY > 0.25`), and ankles/feet visible (`>= footFloorUsed`).
    public static func evaluatePlie(
        _ sample: CalibrationPoseSample,
        standingKneeFlexDeg: Double = 0.0,
        restHipHeightNorm: Double? = nil,
        cameraGravity: CalibrationVector3 = CalibrationVector3(x: 0, y: -1, z: 0),
        passing: Bool = false,
        relaxed: Bool = false,
        bodyMotion: Double? = nil,
        isLatched: Bool = false,
        tuning u: CalibrationTuning = .defaults
    ) -> PlieEvaluation {
        let pts = sample.landmarks
        var visDelta = 0.0
        if relaxed { visDelta = max(visDelta, u.relaxVisibilityDelta) }
        if passing { visDelta = max(visDelta, u.framingStayVisibilityDelta) }
        let footFloorUsed = u.footMinVisibility - visDelta

        let anklesAndFeet = ["leftAnkle", "rightAnkle"] + footJoints
        let feetVisibleOK = (anklesAndFeet.map { visibility(pts, $0) }.min() ?? 0.0) >= footFloorUsed

        let tScore = CalibrationGate.tPoseScore(sample, tuning: u)
        let armsOutOK = tScore.sY > 0.25

        var meanKneeFlexDeg: Double?
        var hipHeightNorm: Double?
        var plieHipDropNorm: Double?
        if let frame = sample.frame {
            let posture = extractPostureMetrics(frame: frame, cameraGravity: cameraGravity)
            meanKneeFlexDeg = posture.meanKneeFlexDeg
            hipHeightNorm = posture.hipHeightNorm
            if let curHipH = posture.hipHeightNorm {
                let baseline = restHipHeightNorm ?? posture.straightLegHipHeightNorm ?? 1.0
                plieHipDropNorm = baseline - curHipH
            }
        }

        let requiredFlexDeg = max(u.plieMinKneeFlexDeg, standingKneeFlexDeg + 15.0)
        let kneeFlexOK = meanKneeFlexDeg.map { $0 >= requiredFlexDeg } ?? false
        let hipDropOK = plieHipDropNorm.map { $0 >= u.plieMinHipDropNorm } ?? false

        let motionLimit = isLatched ? PoseKind.plie.motionStayMax(tuning: u) : PoseKind.plie.motionEnterMax(tuning: u)
        let stillOK = bodyMotion.map { $0 <= motionLimit } ?? true

        let passes = kneeFlexOK && hipDropOK && armsOutOK && feetVisibleOK && stillOK
        let cue: PoseCue
        if !feetVisibleOK {
            cue = .stepBackShowFeet
        } else if !armsOutOK {
            cue = .armsOutT
        } else if !(kneeFlexOK && hipDropOK) {
            cue = .bendKneesDeeper
        } else if !stillOK {
            cue = .holdStill
        } else {
            cue = .none
        }

        return PlieEvaluation(
            kneeFlexOK: kneeFlexOK,
            hipDropOK: hipDropOK,
            armsOutOK: armsOutOK,
            feetVisibleOK: feetVisibleOK,
            meanKneeFlexDeg: meanKneeFlexDeg,
            hipHeightNorm: hipHeightNorm,
            plieHipDropNorm: plieHipDropNorm,
            tPoseSY: tScore.sY,
            stillOK: stillOK,
            passes: passes,
            cue: cue
        )
    }

    // MARK: - Pose 7: `.turned45` Evaluator (§2.2 Pose 7)

    /// Evaluation result for Pose 7 (`.turned45`, `stepIndex 9`, §2.2).
    public struct Turned45Evaluation: Equatable, Sendable {
        public var shoulderWidth2D: Double?
        public var shoulderWidthOK: Bool
        public var shoulderYawDeg: Double?
        public var yawInWindowOK: Bool
        public var armsExtendedOK: Bool
        public var tPoseSAng: Double
        public var obliqueTrackingConfidence: Double?
        public var stillOK: Bool
        public var passes: Bool
        public var cue: PoseCue
    }

    /// Evaluates Pose 7 (`.turned45`, §2.2): 2D shoulder width `|ls.x - rs.x| >= 0.045` (`checkup.ts:151`),
    /// canonical 3D shoulder XZ yaw `atan2(|rs3D.z - ls3D.z|, |rs3D.x - ls3D.x|) ∈ [25°, 65°]`, and arms
    /// extended (`sAng > 0.25`).
    public static func evaluateTurned45(
        _ sample: CalibrationPoseSample,
        cameraGravity: CalibrationVector3 = CalibrationVector3(x: 0, y: -1, z: 0),
        bodyMotion: Double? = nil,
        isLatched: Bool = false,
        tuning u: CalibrationTuning = .defaults
    ) -> Turned45Evaluation {
        let pts = sample.landmarks
        let j3D = gravityAlignedJoints(sample.frame, cameraGravity: cameraGravity)

        let ls = landmark(pts, "leftShoulder")
        let rs = landmark(pts, "rightShoulder")
        let shouldersPresent = min(ls?.visibility ?? 0.0, rs?.visibility ?? 0.0) >= u.presenceMinVisibility
        let shoulderWidth2D: Double? = {
            guard let ls, let rs else { return nil }
            return abs(ls.x - rs.x)
        }()
        let shoulderWidthOK = shouldersPresent && (shoulderWidth2D.map { $0 >= u.turnedMinShoulderWidth2D } ?? false)

        let shoulderYawDeg: Double? = {
            guard let ls3 = j3D["leftShoulder"], let rs3 = j3D["rightShoulder"] else { return nil }
            let dx = abs(rs3.x - ls3.x)
            let dz = abs(rs3.z - ls3.z)
            guard hypot(dx, dz) > 1e-6 else { return nil }
            return atan2(dz, dx) * 180.0 / .pi
        }()
        let yawInWindowOK = shoulderYawDeg.map {
            $0 >= u.turnedMinYawDeg && $0 <= u.turnedMaxYawDeg
        } ?? false

        let sAng: Double = {
            guard let ls, let rs,
                  let le = landmark(pts, "leftElbow"),
                  let re = landmark(pts, "rightElbow"),
                  let lw = landmark(pts, "leftWrist"),
                  let rw = landmark(pts, "rightWrist") else {
                return 0.0
            }
            let hidden = [ls, rs, le, re, lw, rw].filter { $0.visibility < u.tPoseArmMinVisibility }.count
            guard hidden <= 2 else { return 0.0 }
            let minElbow = min(angle2DDeg(ls, le, lw), angle2DDeg(rs, re, rw))
            return clamp01((minElbow - 120.0) / 30.0)
        }()
        let armsExtendedOK = sAng > 0.25

        // Far-side joint mean confidence (whichever shoulder has smaller z in canonical camera space is farther).
        let obliqueTrackingConfidence: Double? = {
            guard let ls3 = j3D["leftShoulder"], let rs3 = j3D["rightShoulder"] else { return nil }
            let farPrefix = (ls3.z <= rs3.z) ? "left" : "right"
            let farJoints = ["\(farPrefix)Wrist", "\(farPrefix)Elbow", "\(farPrefix)Hip", "\(farPrefix)Knee"]
            let vals = farJoints.map { visibility(pts, $0) }
            guard !vals.isEmpty else { return nil }
            return vals.reduce(0.0, +) / Double(vals.count)
        }()

        let motionLimit = isLatched ? PoseKind.turned45.motionStayMax(tuning: u) : PoseKind.turned45.motionEnterMax(tuning: u)
        let stillOK = bodyMotion.map { $0 <= motionLimit } ?? true

        let tooEdgeOn = (shouldersPresent && !shoulderWidthOK)
            || (shoulderYawDeg.map { $0 > u.turnedMaxYawDeg } ?? false)
        let passes = shoulderWidthOK && yawInWindowOK && armsExtendedOK && stillOK

        let cue: PoseCue
        if tooEdgeOn {
            cue = .turnLessSideways
        } else if !armsExtendedOK {
            cue = .armsOutT
        } else if !(shoulderWidthOK && yawInWindowOK) {
            cue = .turnBody45
        } else if !stillOK {
            cue = .holdStill
        } else {
            cue = .none
        }

        return Turned45Evaluation(
            shoulderWidth2D: shoulderWidth2D,
            shoulderWidthOK: shoulderWidthOK,
            shoulderYawDeg: shoulderYawDeg,
            yawInWindowOK: yawInWindowOK,
            armsExtendedOK: armsExtendedOK,
            tPoseSAng: sAng,
            obliqueTrackingConfidence: obliqueTrackingConfidence,
            stillOK: stillOK,
            passes: passes,
            cue: cue
        )
    }

    // MARK: - Pose 8: `.stepLeft` & `.stepRight` Evaluators (§2.2 Pose 8)

    /// Direction for Pose 8 (`stepLR`: sub-holds 8a `.left` and 8b `.right`, §2.2).
    public enum StepDirection: String, Codable, Equatable, Sendable {
        case left
        case right
    }

    /// Evaluation result for Pose 8a (`.stepLeft`, `stepIndex 10`) or Pose 8b (`.stepRight`, `stepIndex 11`, §2.2).
    public struct LateralStepEvaluation: Equatable, Sendable {
        public var direction: StepDirection
        public var hipCenterX: Double?
        public var signedHipShiftX: Double?
        public var shiftOK: Bool
        public var safeBoxOK: Bool
        public var coreVisibleOK: Bool
        public var feetVisibleOK: Bool
        public var hipXNorm: Double?
        public var stillOK: Bool
        public var passes: Bool
        public var cue: PoseCue
    }

    /// Computes physical usable lateral floor span (m) across the `[0.04, 0.96]` safe frame width (§6.1):
    /// `(safeMaxX - safeMinX) * 2 * dancerDistanceM * tan(thetaH / 2)`.
    public static func usableLateralSpanM(
        dancerDistanceM: Double,
        horizontalFoVDeg: Double? = nil,
        verticalFoVDeg: Double? = nil,
        safeMinX: Double = 0.04,
        safeMaxX: Double = 0.96
    ) -> Double? {
        guard dancerDistanceM.isFinite, dancerDistanceM > 0, safeMaxX > safeMinX else { return nil }
        let hFoV: Double = {
            if let h = horizontalFoVDeg, h.isFinite, h > 0, h < 180.0 { return h }
            if let v = verticalFoVDeg, v.isFinite, v > 0, v < 180.0 {
                return CalibrationIntrinsics.portraitHorizontalFoVDeg(fromVerticalFoVDeg: v)
            }
            return 0.0
        }()
        guard hFoV > 0 else { return nil }
        let tanHalfH = tan((hFoV * .pi / 180.0) * 0.5)
        return (safeMaxX - safeMinX) * 2.0 * dancerDistanceM * tanHalfH
    }

    /// Evaluates Pose 8a (`.stepLeft`, `hipCenterX - restHipCenterX >= 0.12`, safeBox `[0.04, 0.96]`; §2.2).
    public static func evaluateStepLeft(
        _ sample: CalibrationPoseSample,
        restHipCenterX: Double = 0.50,
        cameraGravity: CalibrationVector3 = CalibrationVector3(x: 0, y: -1, z: 0),
        passing: Bool = false,
        relaxed: Bool = false,
        bodyMotion: Double? = nil,
        isLatched: Bool = false,
        tuning u: CalibrationTuning = .defaults
    ) -> LateralStepEvaluation {
        evaluateLateralStep(
            sample,
            direction: .left,
            restHipCenterX: restHipCenterX,
            cameraGravity: cameraGravity,
            passing: passing,
            relaxed: relaxed,
            bodyMotion: bodyMotion,
            isLatched: isLatched,
            tuning: u
        )
    }

    /// Evaluates Pose 8b (`.stepRight`, `restHipCenterX - hipCenterX >= 0.12`, safeBox `[0.04, 0.96]`; §2.2).
    public static func evaluateStepRight(
        _ sample: CalibrationPoseSample,
        restHipCenterX: Double = 0.50,
        cameraGravity: CalibrationVector3 = CalibrationVector3(x: 0, y: -1, z: 0),
        passing: Bool = false,
        relaxed: Bool = false,
        bodyMotion: Double? = nil,
        isLatched: Bool = false,
        tuning u: CalibrationTuning = .defaults
    ) -> LateralStepEvaluation {
        evaluateLateralStep(
            sample,
            direction: .right,
            restHipCenterX: restHipCenterX,
            cameraGravity: cameraGravity,
            passing: passing,
            relaxed: relaxed,
            bodyMotion: bodyMotion,
            isLatched: isLatched,
            tuning: u
        )
    }

    /// Shared lateral-step evaluator for `.stepLeft` and `.stepRight` (§2.2 Pose 8).
    public static func evaluateLateralStep(
        _ sample: CalibrationPoseSample,
        direction: StepDirection,
        restHipCenterX: Double = 0.50,
        cameraGravity: CalibrationVector3 = CalibrationVector3(x: 0, y: -1, z: 0),
        passing: Bool = false,
        relaxed: Bool = false,
        bodyMotion: Double? = nil,
        isLatched: Bool = false,
        tuning u: CalibrationTuning = .defaults
    ) -> LateralStepEvaluation {
        let pts = sample.landmarks
        var visDelta = 0.0
        if relaxed { visDelta = max(visDelta, u.relaxVisibilityDelta) }
        if passing { visDelta = max(visDelta, u.framingStayVisibilityDelta) }
        let coreFloor = u.coreMinVisibility - visDelta
        let footFloor = u.footMinVisibility - visDelta

        let coreVisibleOK = (coreJoints.map { visibility(pts, $0) }.min() ?? 0.0) >= coreFloor
        let feetVisibleOK = (footJoints.map { visibility(pts, $0) }.min() ?? 0.0) >= footFloor

        let boxPoints = (coreJoints + footJoints).compactMap { landmark(pts, $0) }
        let minX = boxPoints.map(\.x).min() ?? 0.0
        let maxX = boxPoints.map(\.x).max() ?? 1.0
        let safeBoxOK = !boxPoints.isEmpty && minX >= 0.04 && maxX <= 0.96

        let hipX = hipCenterX2D(pts)
        // Dancer's own left corresponds to larger un-mirrored x; dancer's own right corresponds to smaller x.
        let signedShift: Double? = hipX.map { hx in
            switch direction {
            case .left: return hx - restHipCenterX
            case .right: return restHipCenterX - hx
            }
        }
        let shiftOK = signedShift.map { $0 >= u.stepMinHipShiftX } ?? false

        let hipXNorm: Double? = sample.frame.flatMap {
            extractPostureMetrics(frame: $0, cameraGravity: cameraGravity).hipXNorm
        }

        let poseKind: PoseKind = (direction == .left) ? .stepLeft : .stepRight
        let motionLimit = isLatched ? poseKind.motionStayMax(tuning: u) : poseKind.motionEnterMax(tuning: u)
        let stillOK = bodyMotion.map { $0 <= motionLimit } ?? true

        let passes = shiftOK && safeBoxOK && coreVisibleOK && feetVisibleOK && stillOK
        let entryCue: PoseCue = (direction == .left) ? .stepLeft : .stepRight
        let cue: PoseCue
        if !safeBoxOK && !boxPoints.isEmpty {
            cue = .stepBackLateralRoom
        } else if !feetVisibleOK {
            cue = .stepBackShowFeet
        } else if !(shiftOK && coreVisibleOK) {
            cue = entryCue
        } else if !stillOK {
            cue = .holdStill
        } else {
            cue = .none
        }

        return LateralStepEvaluation(
            direction: direction,
            hipCenterX: hipX,
            signedHipShiftX: signedShift,
            shiftOK: shiftOK,
            safeBoxOK: safeBoxOK,
            coreVisibleOK: coreVisibleOK,
            feetVisibleOK: feetVisibleOK,
            hipXNorm: hipXNorm,
            stillOK: stillOK,
            passes: passes,
            cue: cue
        )
    }

    // MARK: - Pose 9: `.kneeLift` Evaluator (§2.2 Pose 9)

    /// Evaluation result for Pose 9 (`.kneeLift`, `stepIndex 12`, §2.2).
    public struct KneeLiftEvaluation: Equatable, Sendable {
        public var maxKneeFlexDeg: Double?
        public var kneeFlexOK: Bool
        public var ankleClearanceRatio: Double?
        public var ankleClearanceOK: Bool
        public var standingSupportVisibleOK: Bool
        public var liftedFootVisibleOK: Bool
        public var liftedSide: String?
        public var stillOK: Bool
        public var passes: Bool
        public var cue: PoseCue
    }

    /// Evaluates Pose 9 (`.kneeLift`, §2.2): `max(leftKneeFlex, rightKneeFlex) >= 55°` exterior flexion,
    /// gravity-aligned ankle height delta `|la3D.y - ra3D.y| >= 0.18 * legScale`, standing ankle + both knees
    /// `>= coreFloorUsed` (and standing foot `>= footFloorUsed`), lifted heel/toe `>= footFloorUsed - 0.05`,
    /// and relaxed single-leg sway (`0.025` / `0.035`).
    public static func evaluateKneeLift(
        _ sample: CalibrationPoseSample,
        cameraGravity: CalibrationVector3 = CalibrationVector3(x: 0, y: -1, z: 0),
        passing: Bool = false,
        relaxed: Bool = false,
        bodyMotion: Double? = nil,
        isLatched: Bool = false,
        tuning u: CalibrationTuning = .defaults
    ) -> KneeLiftEvaluation {
        let pts = sample.landmarks
        var visDelta = 0.0
        if relaxed { visDelta = max(visDelta, u.relaxVisibilityDelta) }
        if passing { visDelta = max(visDelta, u.framingStayVisibilityDelta) }
        let coreFloor = u.coreMinVisibility - visDelta
        let footFloor = u.footMinVisibility - visDelta
        let liftedFootFloor = max(0.0, footFloor - 0.05)

        let j3D = gravityAlignedJoints(sample.frame, cameraGravity: cameraGravity)

        var maxKneeFlexDeg: Double?
        var ankleClearanceRatio: Double?
        var liftedSide: String?

        if let frame = sample.frame {
            let posture = extractPostureMetrics(frame: frame, cameraGravity: cameraGravity)
            if let lFlex = posture.leftKneeFlexDeg, let rFlex = posture.rightKneeFlexDeg {
                maxKneeFlexDeg = max(lFlex, rFlex)
            }
            if let la3 = j3D["leftAnkle"], let ra3 = j3D["rightAnkle"], let legScale = posture.legScale, legScale > 1e-6 {
                ankleClearanceRatio = abs(la3.y - ra3.y) / legScale
                liftedSide = (la3.y >= ra3.y) ? "left" : "right"
            }
        }

        if liftedSide == nil {
            // 2D fallback side selection (smaller 2D y = higher in portrait image).
            if let la2 = landmark(pts, "leftAnkle"), let ra2 = landmark(pts, "rightAnkle") {
                liftedSide = (la2.y <= ra2.y) ? "left" : "right"
            }
        }

        let standingPrefix = (liftedSide == "right") ? "left" : "right"
        let liftedPrefix = (liftedSide == "right") ? "right" : "left"

        let kneesVis = min(visibility(pts, "leftKnee"), visibility(pts, "rightKnee"))
        let standingAnkleVis = visibility(pts, "\(standingPrefix)Ankle")
        let standingFootVis = min(
            visibility(pts, "\(standingPrefix)Heel"),
            visibility(pts, "\(standingPrefix)FootIndex")
        )
        let standingSupportVisibleOK = kneesVis >= coreFloor
            && standingAnkleVis >= coreFloor
            && standingFootVis >= footFloor

        let liftedFootVis = min(
            visibility(pts, "\(liftedPrefix)Heel"),
            visibility(pts, "\(liftedPrefix)FootIndex")
        )
        let liftedFootVisibleOK = liftedFootVis >= liftedFootFloor

        let kneeFlexOK = maxKneeFlexDeg.map { $0 >= u.kneeLiftMinFlexDeg } ?? false
        let ankleClearanceOK = ankleClearanceRatio.map { $0 >= u.kneeLiftMinAnkleClearance } ?? false

        let motionLimit = isLatched ? PoseKind.kneeLift.motionStayMax(tuning: u) : PoseKind.kneeLift.motionEnterMax(tuning: u)
        let stillOK = bodyMotion.map { $0 <= motionLimit } ?? true

        let passes = kneeFlexOK && ankleClearanceOK && standingSupportVisibleOK && liftedFootVisibleOK && stillOK
        let cue: PoseCue
        if !standingSupportVisibleOK {
            cue = .stepBackShowFeet
        } else if !(kneeFlexOK && ankleClearanceOK && liftedFootVisibleOK) {
            cue = .liftKnee
        } else if !stillOK {
            cue = .holdStill
        } else {
            cue = .none
        }

        return KneeLiftEvaluation(
            maxKneeFlexDeg: maxKneeFlexDeg,
            kneeFlexOK: kneeFlexOK,
            ankleClearanceRatio: ankleClearanceRatio,
            ankleClearanceOK: ankleClearanceOK,
            standingSupportVisibleOK: standingSupportVisibleOK,
            liftedFootVisibleOK: liftedFootVisibleOK,
            liftedSide: liftedSide,
            stillOK: stillOK,
            passes: passes,
            cue: cue
        )
    }

    // MARK: - Shared PoseHoldTracker (§7.1)

    /// Per-sample outcome returned by `PoseHoldTracker.update(...)` (§7.1).
    public struct HoldStepOutcome: Equatable, Sendable {
        public var completed: Bool
        /// True when framing failed continuously for longer than `dropoutToleranceS`, signalling reset to `.rest`.
        public var framingLost: Bool
        public var progress: Double
        public var elapsedS: Double
        public var holdSamples: Int
        public var motionLimitUsed: Double
        public var bodyStillOK: Bool
        public var cue: PoseCue

        public init(
            completed: Bool,
            framingLost: Bool,
            progress: Double,
            elapsedS: Double,
            holdSamples: Int,
            motionLimitUsed: Double,
            bodyStillOK: Bool,
            cue: PoseCue
        ) {
            self.completed = completed
            self.framingLost = framingLost
            self.progress = progress
            self.elapsedS = elapsedS
            self.holdSamples = holdSamples
            self.motionLimitUsed = motionLimitUsed
            self.bodyStillOK = bodyStillOK
            self.cue = cue
        }
    }

    /// Shared monotonic-clock hold, dropout-tolerance, and framing-loss tracker across Poses 1–9 (§7.1).
    public struct PoseHoldTracker: Sendable {
        public private(set) var poseStart: Double?
        public private(set) var poseLastGood: Double?
        public private(set) var poseLatched: Bool = false
        public private(set) var holdSamples: Int = 0
        public private(set) var frameFailSince: Double?
        public private(set) var lastProgress: Double = 0.0
        public private(set) var capturedFrames: [GrooveScoringEngine.RawPoseFrame] = []

        public init() {}

        /// Resets hold timing, sample counters, and captured frames (keeps or clears `frameFailSince`).
        public mutating func reset(clearFramingFailure: Bool = true) {
            poseStart = nil
            poseLastGood = nil
            poseLatched = false
            holdSamples = 0
            lastProgress = 0.0
            capturedFrames = []
            if clearFramingFailure {
                frameFailSince = nil
            }
        }

        /// Advances the hold state for `pose` at monotonic `timestamp`.
        /// - Parameters:
        ///   - pose: Which of the 9 poses (or step sub-holds) is active.
        ///   - timestamp: Monotonic pose-stream seconds.
        ///   - posePasses: Whether the stateless pose geometry & visibility check passed on this sample.
        ///   - poseFailureCue: Diagnostic cue to report when `posePasses == false`.
        ///   - framingCue: Cue from `evaluateFraming(..., forPose: pose, passing: true)` (`.none` when framed).
        ///   - bodyMotion: Normalized body displacement (`nil` on initial sample before motion delta exists).
        ///   - frame: Optional `RawPoseFrame` appended to `capturedFrames` on good samples.
        ///   - holdDurationOverrideS: Optional hold override (e.g. `0.4 s` Tier-0 `.rest` quick resume).
        ///   - dropoutOverrideS: Optional dropout tolerance override.
        ///   - minSamplesOverride: Optional minimum sample count override.
        ///   - tuning: Active `CalibrationTuning`.
        public mutating func update(
            pose: PoseKind,
            timestamp: Double,
            posePasses: Bool,
            poseFailureCue: PoseCue,
            framingCue: PoseCue = .none,
            bodyMotion: Double? = 0.0,
            frame: GrooveScoringEngine.RawPoseFrame? = nil,
            holdDurationOverrideS: Double? = nil,
            dropoutOverrideS: Double? = nil,
            minSamplesOverride: Int? = nil,
            tuning u: CalibrationTuning = .defaults
        ) -> HoldStepOutcome {
            let requiredHoldS = holdDurationOverrideS ?? pose.holdDurationS(tuning: u)
            let dropoutS = dropoutOverrideS ?? pose.dropoutToleranceS(tuning: u)
            let requiredSamples = minSamplesOverride ?? pose.minCapturedSamples(tuning: u)
            let motionLimit = poseLatched ? pose.motionStayMax(tuning: u) : pose.motionEnterMax(tuning: u)
            let stillOK = bodyMotion.map { $0 <= motionLimit } ?? false

            // 1. Continuous framing loss beyond dropoutToleranceS sends calibration back to Pose 1 (.rest).
            if framingCue != .none {
                let since = frameFailSince ?? timestamp
                frameFailSince = since
                if timestamp - since > dropoutS {
                    reset(clearFramingFailure: true)
                    return HoldStepOutcome(
                        completed: false,
                        framingLost: true,
                        progress: 0.0,
                        elapsedS: 0.0,
                        holdSamples: 0,
                        motionLimitUsed: motionLimit,
                        bodyStillOK: stillOK,
                        cue: framingCue
                    )
                }
            } else {
                frameFailSince = nil
            }

            let good = (framingCue == .none) && posePasses && stillOK

            if good {
                if let last = poseLastGood, timestamp - last > dropoutS {
                    reset(clearFramingFailure: false)
                }
                if poseStart == nil {
                    poseStart = timestamp
                    holdSamples = 0
                    capturedFrames = []
                }
                poseLatched = true
                poseLastGood = timestamp
                holdSamples += 1
                if let frame {
                    capturedFrames.append(frame)
                }
            } else if let last = poseLastGood, timestamp - last <= dropoutS {
                // Tolerated dropout: preserve hold timer and progress, capture nothing.
                let elapsed = max(0.0, timestamp - (poseStart ?? timestamp))
                let progress = min(0.99, requiredHoldS > 0 ? clamp01(elapsed / requiredHoldS) : 1.0)
                lastProgress = progress
                return HoldStepOutcome(
                    completed: false,
                    framingLost: false,
                    progress: progress,
                    elapsedS: elapsed,
                    holdSamples: holdSamples,
                    motionLimitUsed: motionLimit,
                    bodyStillOK: stillOK,
                    cue: .holdStill
                )
            } else {
                reset(clearFramingFailure: false)
                let failCue: PoseCue
                if framingCue != .none {
                    failCue = framingCue
                } else if !posePasses {
                    failCue = (poseFailureCue == .none) ? pose.entryCue : poseFailureCue
                } else {
                    failCue = .holdStill
                }
                return HoldStepOutcome(
                    completed: false,
                    framingLost: false,
                    progress: 0.0,
                    elapsedS: 0.0,
                    holdSamples: 0,
                    motionLimitUsed: motionLimit,
                    bodyStillOK: stillOK,
                    cue: failCue
                )
            }

            let elapsed = max(0.0, timestamp - (poseStart ?? timestamp))
            if elapsed >= requiredHoldS && holdSamples >= requiredSamples {
                lastProgress = 1.0
                return HoldStepOutcome(
                    completed: true,
                    framingLost: false,
                    progress: 1.0,
                    elapsedS: elapsed,
                    holdSamples: holdSamples,
                    motionLimitUsed: motionLimit,
                    bodyStillOK: stillOK,
                    cue: .none
                )
            }

            let progress = min(0.99, requiredHoldS > 0 ? clamp01(elapsed / requiredHoldS) : 1.0)
            lastProgress = progress
            return HoldStepOutcome(
                completed: false,
                framingLost: false,
                progress: progress,
                elapsedS: elapsed,
                holdSamples: holdSamples,
                motionLimitUsed: motionLimit,
                bodyStillOK: stillOK,
                cue: .holdStill
            )
        }
    }

    // MARK: - LiDAR Metric Scale, Bone Lengths, Wingspan, ROM & Confidence Aggregators (§1.2, §2.2, §6.1, §8.1–8.3)

    /// Rigid canonical child-bone keys prioritized when computing LiDAR-to-MediaPipe `metricScaleFactor` (§1.2):
    /// shoulders, upper arms, forearms, thighs, and shins.
    public static let scaleReferenceBoneKeys: Set<String> = [
        "leftShoulder", "rightShoulder",
        "leftElbow", "rightElbow",
        "leftWrist", "rightWrist",
        "leftKnee", "rightKnee",
        "leftAnkle", "rightAnkle"
    ]

    static func median(_ values: [Double]) -> Double? {
        let finite = values.filter { $0.isFinite }.sorted()
        guard !finite.isEmpty else { return nil }
        let n = finite.count
        if n % 2 == 1 {
            return finite[n / 2]
        }
        return 0.5 * (finite[n / 2 - 1] + finite[n / 2])
    }

    static func percentile(_ values: [Double], q: Double) -> Double? {
        let finite = values.filter { $0.isFinite }.sorted()
        guard !finite.isEmpty else { return nil }
        let clampedQ = clamp01(q)
        let pos = clampedQ * Double(finite.count - 1)
        let lo = Int(pos.rounded(.down))
        let hi = Int(pos.rounded(.up))
        let frac = pos - Double(lo)
        return finite[lo] * (1.0 - frac) + finite[hi] * frac
    }

    /// Computes `metricScaleFactor = median(L_lidar / L_mp)` from per-bone MediaPipe lengths and LiDAR metric
    /// lengths (`1.0` when no valid overlapping bone pairs exist; §1.2, §2.2 Pose 2).
    public static func metricScaleFactor(
        mpBoneLengths: [String: Double],
        lidarBoneLengthsM: [String: Double],
        clampRange: ClosedRange<Double> = 0.50...2.00
    ) -> Double {
        var preferredRatios: [Double] = []
        var allRatios: [Double] = []

        for key in lidarBoneLengthsM.keys.sorted() {
            guard let lidarLen = lidarBoneLengthsM[key],
                  let mpLen = mpBoneLengths[key],
                  lidarLen.isFinite, mpLen.isFinite,
                  lidarLen > 1e-4, mpLen > 1e-4 else {
                continue
            }
            let ratio = lidarLen / mpLen
            guard ratio.isFinite, ratio > 0 else { continue }
            allRatios.append(ratio)
            if scaleReferenceBoneKeys.contains(key) {
                preferredRatios.append(ratio)
            }
        }

        let chosen = preferredRatios.isEmpty ? allRatios : preferredRatios
        guard let med = median(chosen) else { return 1.0 }
        return clamp(med, clampRange.lowerBound, clampRange.upperBound)
    }

    /// Computes `metricScaleFactor = median(L_lidar / L_mp)` across captured T-pose `RawPoseFrame`s and
    /// `CalibrationDepthSample`s (`1.0` when `depthSamples` has no valid bone lengths; §1.2, §2.2 Pose 2).
    public static func metricScaleFactor(
        tPoseFrames: [GrooveScoringEngine.RawPoseFrame],
        depthSamples: [CalibrationDepthSample],
        clampRange: ClosedRange<Double> = 0.50...2.00
    ) -> Double {
        guard !tPoseFrames.isEmpty, !depthSamples.isEmpty else { return 1.0 }
        let mpMedians = GrooveScoringEngine.Retarget.medianBoneLengths(tPoseFrames)
        guard !mpMedians.isEmpty else { return 1.0 }

        var lidarSamplesByBone: [String: [Double]] = [:]
        for sample in depthSamples {
            for (bone, lengthM) in sample.lidarBoneLengthsM where lengthM.isFinite && lengthM > 1e-4 {
                lidarSamplesByBone[bone, default: []].append(lengthM)
            }
        }
        var lidarMedians: [String: Double] = [:]
        for (bone, values) in lidarSamplesByBone {
            if let med = median(values) {
                lidarMedians[bone] = med
            }
        }
        return metricScaleFactor(
            mpBoneLengths: mpMedians,
            lidarBoneLengthsM: lidarMedians,
            clampRange: clampRange
        )
    }

    /// Computes all 19 canonical bone lengths in physical metres (`medianBoneLengths(tPoseFrames) * metricScaleFactor`, §2.2, §8.1).
    public static func calibratedBoneLengthsM(
        tPoseFrames: [GrooveScoringEngine.RawPoseFrame],
        metricScaleFactor: Double = 1.0
    ) -> [String: Double] {
        let scale = (metricScaleFactor.isFinite && metricScaleFactor > 0) ? metricScaleFactor : 1.0
        let raw = GrooveScoringEngine.Retarget.medianBoneLengths(tPoseFrames)
        return raw.mapValues { $0 * scale }
    }

    /// Computes wrist-to-wrist `wingspanM` as the sum of the 6 canonical L/R arm segments
    /// (`leftShoulder + leftElbow + leftWrist + rightShoulder + rightElbow + rightWrist`) in `boneLengthsM` (§2.2, §6.1).
    public static func wristToWristWingspanM(from boneLengthsM: [String: Double]) -> Double? {
        CalibrationProfileV2.Body.wristToWristWingspanM(from: boneLengthsM)
    }

    /// Computes wrist-to-wrist `wingspanM` from `boneLengthsM`, falling back to `0.85 * dancerHeightM` when
    /// any of the 6 arm segments is missing (§3.2, §6.1).
    public static func wingspanM(
        from boneLengthsM: [String: Double],
        dancerHeightM: Double? = nil
    ) -> Double {
        if let exact = wristToWristWingspanM(from: boneLengthsM) {
            return exact
        }
        let h = (dancerHeightM.flatMap { $0.isFinite && $0 > 0 ? $0 : nil })
            ?? CalibrationProfileV2.defaultDancerHeightM
        return CalibrationProfileV2.defaultWingspanToHeightRatio * h
    }

    /// Builds a `CalibrationROM` summary from scalar series collected during Poses 1, 3, 6, and 9 (§6.1, §8.2).
    public static func buildROM(
        standingKneeFlexValues: [Double] = [],
        trunkLeanValues: [Double] = [],
        shoulderElevationValues: [Double] = [],
        plieKneeFlexValues: [Double] = [],
        plieHipDropValues: [Double] = [],
        kneeLiftFlexValues: [Double] = [],
        defaults: CalibrationROM = CalibrationROM()
    ) -> CalibrationROM {
        let standingKnee = median(standingKneeFlexValues) ?? defaults.standingKneeFlexDeg
        let trunkLean = median(trunkLeanValues) ?? defaults.trunkLeanBaselineDeg
        let maxShoulder = shoulderElevationValues.filter(\.isFinite).max() ?? defaults.maxShoulderElevationDeg
        let plieKnee = median(plieKneeFlexValues) ?? defaults.plieKneeFlexDeg
        let plieDrop = median(plieHipDropValues).map { max(0.0, $0) } ?? defaults.plieHipDropNorm
        let maxKneeLift = kneeLiftFlexValues.filter(\.isFinite).max() ?? defaults.maxKneeLiftFlexDeg

        return CalibrationROM(
            standingKneeFlexDeg: standingKnee,
            plieKneeFlexDeg: plieKnee,
            plieHipDropNorm: plieDrop,
            maxShoulderElevationDeg: maxShoulder,
            maxKneeLiftFlexDeg: maxKneeLift,
            trunkLeanBaselineDeg: trunkLean
        )
    }

    /// Builds a `CalibrationROM` summary directly from held `CalibrationPoseSample`s across Poses 1, 3, 6, and 9 (§6.1, §8.2).
    public static func buildROM(
        restSamples: [CalibrationPoseSample],
        overheadSamples: [CalibrationPoseSample] = [],
        plieSamples: [CalibrationPoseSample] = [],
        kneeLiftSamples: [CalibrationPoseSample] = [],
        cameraGravity: CalibrationVector3 = CalibrationVector3(x: 0, y: -1, z: 0),
        defaults: CalibrationROM = CalibrationROM()
    ) -> CalibrationROM {
        var standingKnees: [Double] = []
        var trunkLeans: [Double] = []
        var restHipHeights: [Double] = []
        for s in restSamples {
            guard let f = s.frame else { continue }
            let m = extractPostureMetrics(frame: f, cameraGravity: cameraGravity)
            if let k = m.meanKneeFlexDeg { standingKnees.append(k) }
            if let t = m.trunkLeanDeg { trunkLeans.append(t) }
            if let h = m.hipHeightNorm { restHipHeights.append(h) }
        }
        let restHipBaseline = median(restHipHeights)

        var shoulderElevs: [Double] = []
        for s in overheadSamples {
            let j3D = gravityAlignedJoints(s.frame, cameraGravity: cameraGravity)
            if let elev = shoulderElevationAnglesDeg(pts: s.landmarks, joints3D: j3D) {
                shoulderElevs.append(0.5 * (elev.left + elev.right))
            }
        }

        var plieKnees: [Double] = []
        var plieDrops: [Double] = []
        for s in plieSamples {
            guard let f = s.frame else { continue }
            let m = extractPostureMetrics(frame: f, cameraGravity: cameraGravity)
            if let k = m.meanKneeFlexDeg { plieKnees.append(k) }
            if let h = m.hipHeightNorm {
                let base = restHipBaseline ?? m.straightLegHipHeightNorm ?? 1.0
                plieDrops.append(max(0.0, base - h))
            }
        }

        var kneeLifts: [Double] = []
        for s in kneeLiftSamples {
            guard let f = s.frame else { continue }
            let m = extractPostureMetrics(frame: f, cameraGravity: cameraGravity)
            if let lk = m.leftKneeFlexDeg, let rk = m.rightKneeFlexDeg {
                kneeLifts.append(max(lk, rk))
            }
        }

        return buildROM(
            standingKneeFlexValues: standingKnees,
            trunkLeanValues: trunkLeans,
            shoulderElevationValues: shoulderElevs,
            plieKneeFlexValues: plieKnees,
            plieHipDropValues: plieDrops,
            kneeLiftFlexValues: kneeLifts,
            defaults: defaults
        )
    }

    /// Aggregates per-joint reliability weights `w_j = clamp(p25Visibility(j), 0.50, 1.00)` from per-joint
    /// visibility series (§8.3).
    public static func aggregateJointConfidenceWeights(
        visibilitySeries: [String: [Double]],
        minWeight: Double = 0.50,
        maxWeight: Double = 1.00
    ) -> [String: Double] {
        var out: [String: Double] = [:]
        out.reserveCapacity(visibilitySeries.count)
        for (joint, values) in visibilitySeries {
            guard let p25 = percentile(values, q: 0.25) else { continue }
            out[joint] = clamp(p25, minWeight, maxWeight)
        }
        return out
    }

    /// Aggregates per-joint reliability weights `w_j = clamp(p25Visibility(j), 0.50, 1.00)` across unoccluded
    /// calibration `CalibrationPoseSample`s (§6.1, §8.3).
    public static func aggregateJointConfidenceWeights(
        samples: [CalibrationPoseSample],
        includeSynthesizedJoints: Bool = false,
        minWeight: Double = 0.50,
        maxWeight: Double = 1.00
    ) -> [String: Double] {
        guard !samples.isEmpty else { return [:] }
        var series: [String: [Double]] = [:]
        for sample in samples {
            for (joint, idx) in CanonicalSkeleton.mediapipeIndex where idx < sample.landmarks.count {
                series[joint, default: []].append(sample.landmarks[idx].visibility)
            }
            if includeSynthesizedJoints {
                for (synJoint, sourceIndices) in CanonicalSkeleton.synthesizedSources {
                    let visVals = sourceIndices.compactMap { idx -> Double? in
                        guard idx < sample.landmarks.count else { return nil }
                        return sample.landmarks[idx].visibility
                    }
                    if visVals.count == sourceIndices.count, let minVis = visVals.min() {
                        series[synJoint, default: []].append(minVis)
                    }
                }
            }
        }
        return aggregateJointConfidenceWeights(
            visibilitySeries: series,
            minWeight: minWeight,
            maxWeight: maxWeight
        )
    }

    /// Aggregates per-joint reliability weights `w_j = clamp(p25Visibility(j), 0.50, 1.00)` across canonical
    /// `RawPoseFrame` confidences (§8.3).
    public static func aggregateJointConfidenceWeights(
        frames: [GrooveScoringEngine.RawPoseFrame],
        minWeight: Double = 0.50,
        maxWeight: Double = 1.00
    ) -> [String: Double] {
        guard !frames.isEmpty else { return [:] }
        var series: [String: [Double]] = [:]
        for frame in frames {
            guard let confs = frame.confidences else { continue }
            for (joint, conf) in confs {
                series[joint, default: []].append(conf)
            }
        }
        return aggregateJointConfidenceWeights(
            visibilitySeries: series,
            minWeight: minWeight,
            maxWeight: maxWeight
        )
    }
}
