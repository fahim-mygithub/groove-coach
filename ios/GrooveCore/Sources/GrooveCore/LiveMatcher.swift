import Foundation

private typealias Vec3 = GrooveScoringEngine.Vec3
private typealias Pose = [String: [Double]]

/// Live, ungraded limb feedback for the camera view (spec §3.2 "Adopted", §6 M2). Grading never reads it:
/// `GrooveScoringEngine.scoreAttempt` stays the only score. Foundation-only so linux-ci tests it.
///
/// Feed each live pose frame to `update`. The matcher eases a lag estimate (the learner trails the reference by
/// 0...400 ms) and compares limb directions in the torso frame at that lag. A beat is clean when no limb is off
/// during it; `streak` counts clean beats in a row. Not thread-safe: call from one queue.
public final class LiveMatcher {

    public enum Limb: String, CaseIterable, Sendable {
        case leftUpperArm, leftForearm, rightUpperArm, rightForearm
        case leftThigh, leftShin, rightThigh, rightShin
    }

    /// `ok` below `warnDeg`; `warn` from `warnDeg` to `offDeg`, and also when a joint is not visible; `off` from `offDeg`.
    public enum LimbState: String, Sendable {
        case ok, warn, off
    }

    public struct Thresholds: Sendable, Equatable {
        /// Angle error (degrees) at which a limb turns amber.
        public var warnDeg: Double
        /// Angle error (degrees) at which a limb turns red and its beat is not clean.
        public var offDeg: Double

        public init(warnDeg: Double = 25, offDeg: Double = 50) {
            self.warnDeg = warnDeg
            self.offDeg = offDeg
        }
    }

    public struct LiveState: Sendable, Equatable {
        public let limbs: [Limb: LimbState]
        public let streak: Int
    }

    /// Lag search range and grid, and the easing factor per update (lag += (best - lag) * ease).
    public static let lagRangeMs: ClosedRange<Double> = 0...400
    public static let lagStepMs: Double = 5
    public static let lagEase: Double = 0.08

    /// Seconds the learner currently trails the reference. Display only, never graded.
    public private(set) var lagSeconds: Double = 0

    /// Consecutive clean beats (no limb off).
    public private(set) var streak: Int = 0

    private let reference: [GrooveScoringEngine.RawPoseFrame]
    private let beatTimes: [Double]
    private let rate: Double
    private let mirrored: Bool
    private let gravity: Vec3
    private let thresholds: Thresholds

    /// Index of the reference beat we are in (-1 before the first beat), and whether a limb went off in it.
    private var beatIndex = -1
    private var beatMissed = false

    private static let limbBones: [(limb: Limb, from: String, to: String)] = [
        (.leftUpperArm, "leftShoulder", "leftElbow"), (.leftForearm, "leftElbow", "leftWrist"),
        (.rightUpperArm, "rightShoulder", "rightElbow"), (.rightForearm, "rightElbow", "rightWrist"),
        (.leftThigh, "leftHip", "leftKnee"), (.leftShin, "leftKnee", "leftAnkle"),
        (.rightThigh, "rightHip", "rightKnee"), (.rightShin, "rightKnee", "rightAnkle")
    ]

    /// - Parameters:
    ///   - reference: canonical frames of the current segment at 1x, in reference time.
    ///   - beatTimes: beat times in reference time, ascending.
    ///   - rate: playback rate of the segment (reference time = (mediaTime - lag) * rate).
    ///   - mirrored: true when the learner's camera mirrors them (the phone faces the learner).
    public init(
        reference: [GrooveScoringEngine.RawPoseFrame],
        beatTimes: [Double],
        rate: Double = 1.0,
        mirrored: Bool = false,
        gravityVector: [Double]? = nil,
        thresholds: Thresholds = Thresholds()
    ) {
        precondition(rate > 0, "LiveMatcher rate must be positive")
        self.reference = reference
        self.beatTimes = beatTimes
        self.rate = rate
        self.mirrored = mirrored
        self.gravity = Vec3(array: gravityVector ?? [0.0, -1.0, 0.0])
        self.thresholds = thresholds
    }

    /// Judge one live frame. `mediaTime` is the learner's playback time; the frame's own `t` is only used for pose
    /// interpolation of that single frame.
    public func update(frame: GrooveScoringEngine.RawPoseFrame, mediaTime: Double) -> LiveState {
        let learner = LiveMatcher.limbDirections(
            GrooveScoringEngine.bodyNormalizedPose(frames: [frame], at: frame.t, gravityVector: gravity, mirror: mirrored)
        )
        if let best = bestLag(learner: learner, mediaTime: mediaTime) {
            lagSeconds += (best - lagSeconds) * LiveMatcher.lagEase
        }

        let refTime = (mediaTime - lagSeconds) * rate
        let ref = referenceDirections(at: refTime)
        var limbs: [Limb: LimbState] = [:]
        for limb in Limb.allCases {
            limbs[limb] = state(learner[limb], ref[limb])
        }
        advanceBeats(refTime: refTime, anyOff: limbs.values.contains(.off))
        return LiveState(limbs: limbs, streak: streak)
    }

    // MARK: - Private

    /// Lag (seconds) in the search range whose reference pose best matches the learner. Ties keep the earliest lag.
    private func bestLag(learner: [Limb: Vec3], mediaTime: Double) -> Double? {
        guard !learner.isEmpty, !reference.isEmpty else { return nil }
        var best: Double?
        var bestError = Double.infinity
        var ms = LiveMatcher.lagRangeMs.lowerBound
        while ms <= LiveMatcher.lagRangeMs.upperBound {
            let lag = ms / 1000.0
            let ref = referenceDirections(at: (mediaTime - lag) * rate)
            if let error = meanError(learner, ref), error < bestError {
                bestError = error
                best = lag
            }
            ms += LiveMatcher.lagStepMs
        }
        return best
    }

    private func referenceDirections(at t: Double) -> [Limb: Vec3] {
        LiveMatcher.limbDirections(
            GrooveScoringEngine.bodyNormalizedPose(frames: reference, at: t, gravityVector: gravity, mirror: false)
        )
    }

    private func state(_ learner: Vec3?, _ ref: Vec3?) -> LimbState {
        guard let l = learner, let r = ref else { return .warn }
        let error = LiveMatcher.angleDegrees(l, r)
        if error >= thresholds.offDeg { return .off }
        if error >= thresholds.warnDeg { return .warn }
        return .ok
    }

    /// Finalise the previous beat when the reference enters a new one, then mark the current beat if a limb is off.
    private func advanceBeats(refTime: Double, anyOff: Bool) {
        let index = beatTimes.lastIndex(where: { $0 <= refTime }) ?? -1
        if index != beatIndex {
            if beatIndex >= 0 {
                streak = beatMissed ? 0 : streak + 1
            }
            beatIndex = index
            beatMissed = false
        }
        if beatIndex >= 0 && anyOff {
            beatMissed = true
        }
    }

    /// Mean angle error over the limbs both sides have, or nil when they share none.
    private func meanError(_ a: [Limb: Vec3], _ b: [Limb: Vec3]) -> Double? {
        var total = 0.0
        var count = 0
        for (limb, va) in a {
            guard let vb = b[limb] else { continue }
            total += LiveMatcher.angleDegrees(va, vb)
            count += 1
        }
        return count > 0 ? total / Double(count) : nil
    }

    /// Unit bone directions of every limb in the torso frame. Same Gram-Schmidt as
    /// `GrooveScoringEngine.torsoFrameArmVectors`, extended to the legs. Bones with a missing joint are left out.
    private static func limbDirections(_ pose: Pose) -> [Limb: Vec3] {
        guard let lh = pose["leftHip"], let rh = pose["rightHip"], let cs = pose["centerShoulder"],
              lh.count >= 3, rh.count >= 3, cs.count >= 3 else { return [:] }
        let e1 = Vec3(rh[0] - lh[0], rh[1] - lh[1], rh[2] - lh[2]).normalized
        let up = Vec3(cs[0], cs[1], cs[2])
        let e2 = (up - e1 * Vec3.dot(up, e1)).normalized
        guard e1.norm >= 0.5, e2.norm >= 0.5 else { return [:] }
        let e3 = Vec3.cross(e1, e2)
        var out: [Limb: Vec3] = [:]
        for bone in limbBones {
            guard let a = pose[bone.from], let b = pose[bone.to], a.count >= 3, b.count >= 3 else { continue }
            let v = Vec3(b[0] - a[0], b[1] - a[1], b[2] - a[2])
            let local = Vec3(Vec3.dot(v, e1), Vec3.dot(v, e2), Vec3.dot(v, e3))
            if local.norm > 1e-9 {
                out[bone.limb] = local.normalized
            }
        }
        return out
    }

    private static func angleDegrees(_ a: Vec3, _ b: Vec3) -> Double {
        let c = max(-1.0, min(1.0, Vec3.dot(a, b)))
        return acos(c) * 180.0 / Double.pi
    }
}
