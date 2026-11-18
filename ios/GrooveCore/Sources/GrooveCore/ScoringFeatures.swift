import Foundation

/// Wave-2 scoring components wired into `GrooveScoringEngine.scoreAttempt`, numeric mirror of `groove_eval/scoring.py`:
/// 1. One Euro smoothing of body + foot keypoints before feature extraction (`smoothing`).
/// 2. Hit timing: settle-after-move hits (`MoveSegmenter`) vs the reference's hits on the same beats (`hits`).
/// 3. Per-joint ok/warn/off verdicts + correction hints from golden-performance tolerances (`joint_tolerance`).
/// 4. Hand styling score when hand landmarks are present; absent hands skip the component (`hands`).
/// 5. Lesson windows (`ScoringWindow`): `hand_shape` masks and per-joint tolerance scales.
/// 6. Torso-frame arm bone vectors for the `shape.arm_weight` term.
/// 7. Joint-verdict tolerances widened by reference angular velocity and by occlusion (`tolerance`).
/// New components report but never gate `passed` unless their `gate` flag is set. Every new key defaults to off.
extension GrooveScoringEngine {

    // MARK: - Config

    public struct SmoothingConfig: Sendable, Codable {
        public var enabled: Bool
        public var min_cutoff: Double
        public var beta: Double
        public var d_cutoff: Double

        public init(enabled: Bool = true, min_cutoff: Double = OneEuro.defaultMinCutoff, beta: Double = OneEuro.defaultBeta, d_cutoff: Double = OneEuro.defaultDCutoff) {
            self.enabled = enabled
            self.min_cutoff = min_cutoff
            self.beta = beta
            self.d_cutoff = d_cutoff
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = SmoothingConfig()
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
            min_cutoff = try c.decodeIfPresent(Double.self, forKey: .min_cutoff) ?? d.min_cutoff
            beta = try c.decodeIfPresent(Double.self, forKey: .beta) ?? d.beta
            d_cutoff = try c.decodeIfPresent(Double.self, forKey: .d_cutoff) ?? d.d_cutoff
        }
    }

    public struct HitTimingConfig: Sendable, Codable {
        public var enabled: Bool
        public var gate: Bool
        public var pass_min_score: Double
        public var window_s: Double
        public var moving_threshold: Double
        public var settle_threshold: Double
        public var min_settle_s: Double
        public var beat_tolerance_ms: Double
        public var perfect_max_ms: Double
        public var good_max_ms: Double

        public init(
            enabled: Bool = true,
            gate: Bool = false,
            pass_min_score: Double = 60.0,
            window_s: Double = 0.110,
            moving_threshold: Double = 1.0,
            settle_threshold: Double = 0.4,
            min_settle_s: Double = 0.115,
            beat_tolerance_ms: Double = 150.0,
            perfect_max_ms: Double = 60.0,
            good_max_ms: Double = 120.0
        ) {
            self.enabled = enabled
            self.gate = gate
            self.pass_min_score = pass_min_score
            self.window_s = window_s
            self.moving_threshold = moving_threshold
            self.settle_threshold = settle_threshold
            self.min_settle_s = min_settle_s
            self.beat_tolerance_ms = beat_tolerance_ms
            self.perfect_max_ms = perfect_max_ms
            self.good_max_ms = good_max_ms
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = HitTimingConfig()
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
            gate = try c.decodeIfPresent(Bool.self, forKey: .gate) ?? d.gate
            pass_min_score = try c.decodeIfPresent(Double.self, forKey: .pass_min_score) ?? d.pass_min_score
            window_s = try c.decodeIfPresent(Double.self, forKey: .window_s) ?? d.window_s
            moving_threshold = try c.decodeIfPresent(Double.self, forKey: .moving_threshold) ?? d.moving_threshold
            settle_threshold = try c.decodeIfPresent(Double.self, forKey: .settle_threshold) ?? d.settle_threshold
            min_settle_s = try c.decodeIfPresent(Double.self, forKey: .min_settle_s) ?? d.min_settle_s
            beat_tolerance_ms = try c.decodeIfPresent(Double.self, forKey: .beat_tolerance_ms) ?? d.beat_tolerance_ms
            perfect_max_ms = try c.decodeIfPresent(Double.self, forKey: .perfect_max_ms) ?? d.perfect_max_ms
            good_max_ms = try c.decodeIfPresent(Double.self, forKey: .good_max_ms) ?? d.good_max_ms
        }

        var segmenterConfig: MoveSegmenter.Config {
            MoveSegmenter.Config(
                windowSeconds: window_s,
                movingThreshold: moving_threshold,
                settleThreshold: settle_threshold,
                minSettleSeconds: min_settle_s
            )
        }
    }

    /// Positions are in leg lengths (root-centred, body-normalised), angles in degrees.
    public struct JointToleranceThresholds: Sendable, Codable {
        public var enabled: Bool
        public var k: Double
        public var position_floor: Double
        public var position_ceiling: Double
        public var angle_floor_deg: Double
        public var angle_ceiling_deg: Double
        public var warn_factor: Double

        public init(
            enabled: Bool = true,
            k: Double = 2.0,
            position_floor: Double = 0.06,
            position_ceiling: Double = 0.30,
            angle_floor_deg: Double = 8.0,
            angle_ceiling_deg: Double = 45.0,
            warn_factor: Double = 2.0
        ) {
            self.enabled = enabled
            self.k = k
            self.position_floor = position_floor
            self.position_ceiling = position_ceiling
            self.angle_floor_deg = angle_floor_deg
            self.angle_ceiling_deg = angle_ceiling_deg
            self.warn_factor = warn_factor
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = JointToleranceThresholds()
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
            k = try c.decodeIfPresent(Double.self, forKey: .k) ?? d.k
            position_floor = try c.decodeIfPresent(Double.self, forKey: .position_floor) ?? d.position_floor
            position_ceiling = try c.decodeIfPresent(Double.self, forKey: .position_ceiling) ?? d.position_ceiling
            angle_floor_deg = try c.decodeIfPresent(Double.self, forKey: .angle_floor_deg) ?? d.angle_floor_deg
            angle_ceiling_deg = try c.decodeIfPresent(Double.self, forKey: .angle_ceiling_deg) ?? d.angle_ceiling_deg
            warn_factor = try c.decodeIfPresent(Double.self, forKey: .warn_factor) ?? d.warn_factor
        }

        var moduleConfig: JointTolerance.Config {
            JointTolerance.Config(
                k: k,
                positionFloor: position_floor,
                positionCeiling: position_ceiling,
                angleFloorDeg: angle_floor_deg,
                angleCeilingDeg: angle_ceiling_deg,
                warnFactor: warn_factor
            )
        }
    }

    public struct HandStylingThresholds: Sendable, Codable {
        public var enabled: Bool
        public var gate: Bool
        public var pass_min_score: Double

        public init(enabled: Bool = true, gate: Bool = false, pass_min_score: Double = 60.0) {
            self.enabled = enabled
            self.gate = gate
            self.pass_min_score = pass_min_score
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = HandStylingThresholds()
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
            gate = try c.decodeIfPresent(Bool.self, forKey: .gate) ?? d.gate
            pass_min_score = try c.decodeIfPresent(Double.self, forKey: .pass_min_score) ?? d.pass_min_score
        }
    }

    /// Bone-length retargeting of the reference onto the learner (`Retarget`); off by default.
    public struct RetargetConfig: Sendable, Codable {
        public var enabled: Bool

        public init(enabled: Bool = false) {
            self.enabled = enabled
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? RetargetConfig().enabled
        }
    }

    /// A joint is occluded on a beat when its confidence in the nearest reference or learner frame is below
    /// `min_confidence` (a missing confidence counts as 1), and both wrists are when they are closer than
    /// `wrist_distance` leg lengths in either pose (0 = off). Occluded joints get their tolerance multiplied by
    /// `factor` (1 = off), or with `mask` their beat is left out.
    public struct OcclusionConfig: Sendable, Codable {
        public var min_confidence: Double
        public var wrist_distance: Double
        public var factor: Double
        public var mask: Bool

        public init(min_confidence: Double = 0.5, wrist_distance: Double = 0.0, factor: Double = 1.0, mask: Bool = false) {
            self.min_confidence = min_confidence
            self.wrist_distance = wrist_distance
            self.factor = factor
            self.mask = mask
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = OcclusionConfig()
            min_confidence = try c.decodeIfPresent(Double.self, forKey: .min_confidence) ?? d.min_confidence
            wrist_distance = try c.decodeIfPresent(Double.self, forKey: .wrist_distance) ?? d.wrist_distance
            factor = try c.decodeIfPresent(Double.self, forKey: .factor) ?? d.factor
            mask = try c.decodeIfPresent(Bool.self, forKey: .mask) ?? d.mask
        }
    }

    /// Joint-verdict tolerance scaling. On a beat, tau_j = tau_base * min(velocity_max_factor, 1 + velocity_scale *
    /// |omega_j|), omega_j (rad/s) being the reference's angular velocity at that joint over +/- velocity_half_window_s;
    /// velocity_scale 0 = off (default).
    public struct ToleranceConfig: Sendable, Codable {
        public var velocity_scale: Double
        public var velocity_max_factor: Double
        public var velocity_half_window_s: Double
        public var occlusion: OcclusionConfig

        public init(
            velocity_scale: Double = 0.0,
            velocity_max_factor: Double = 3.0,
            velocity_half_window_s: Double = 0.05,
            occlusion: OcclusionConfig = OcclusionConfig()
        ) {
            self.velocity_scale = velocity_scale
            self.velocity_max_factor = velocity_max_factor
            self.velocity_half_window_s = velocity_half_window_s
            self.occlusion = occlusion
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = ToleranceConfig()
            velocity_scale = try c.decodeIfPresent(Double.self, forKey: .velocity_scale) ?? d.velocity_scale
            velocity_max_factor = try c.decodeIfPresent(Double.self, forKey: .velocity_max_factor) ?? d.velocity_max_factor
            velocity_half_window_s = try c.decodeIfPresent(Double.self, forKey: .velocity_half_window_s) ?? d.velocity_half_window_s
            occlusion = try c.decodeIfPresent(OcclusionConfig.self, forKey: .occlusion) ?? d.occlusion
        }
    }

    /// A lesson manifest window carried by a sliced reference (`lesson_package.slice_reference`): a `mask` listing
    /// "hand_shape" drops the hand-styling samples inside it, and `tolerance_scale` multiplies those joints' verdict
    /// tolerances on the beats inside it (start_s <= t < end_s).
    public struct ScoringWindow: Sendable, Codable {
        public let kind: String?
        public let start_s: Double
        public let end_s: Double
        public let mask: [String]?
        public let tolerance_scale: [String: Double]?

        public init(kind: String? = nil, start_s: Double, end_s: Double, mask: [String]? = nil, tolerance_scale: [String: Double]? = nil) {
            self.kind = kind
            self.start_s = start_s
            self.end_s = end_s
            self.mask = mask
            self.tolerance_scale = tolerance_scale
        }
    }

    // MARK: - Results

    public struct HitJudgment: Sendable, Codable {
        public let count_number: Int
        /// Learner hit minus reference hit on this count (ms); nil for a Miss.
        public let offset_ms: Double?
        public let judgment: String
    }

    public struct HitTimingResult: Sendable, Codable {
        /// "available", "not_applicable" (reference has no hits), or "disabled".
        public let status: String
        public let hit_score: Double?
        public let reference_hit_count: Int
        public let user_hit_count: Int
        public let matched_count: Int
        public let on_beat_ratio: Double?
        public let mean_offset_ms: Double?
        public let per_hit: [HitJudgment]
    }

    public struct JointVerdictSummary: Sendable, Codable {
        public let joint: String
        /// Mean per-beat error: leg lengths for positions, degrees for angles.
        public let error: Double
        public let tolerance: Double
        /// "ok", "warn" or "off".
        public let severity: String
        public let hint: String?
    }

    public struct JointFeedbackResult: Sendable, Codable {
        /// "available", "unavailable" (no comparable poses) or "disabled".
        public let status: String
        public let verdicts: [JointVerdictSummary]
        public let angle_verdicts: [JointVerdictSummary]
        public let top_joint: String?
        public let top_hint: String?
        public let counts: [String: Int]
    }

    public struct HandStylingResult: Sendable, Codable {
        /// "available", "skipped" (no hand landmarks in learner and reference) or "disabled".
        public let status: String
        public let hand_score: Double?
        public let samples: Int
        /// Samples left out by a `hand_shape` window mask.
        public let masked_samples: Int
        public let user_shape: String?
        public let reference_shape: String?
    }

    /// Per-joint tolerances (positions in leg lengths, angles in degrees).
    public struct JointTolerances: Sendable {
        public let positions: [String: Double]
        public let angles: [String: Double]
    }

    // MARK: - Shared helpers

    static let mirrorSwapPairs: [(String, String)] = [
        ("leftHip", "rightHip"),
        ("leftKnee", "rightKnee"),
        ("leftAnkle", "rightAnkle"),
        ("leftShoulder", "rightShoulder"),
        ("leftHeel", "rightHeel"),
        ("leftFootIndex", "rightFootIndex"),
        ("leftElbow", "rightElbow"),
        ("leftWrist", "rightWrist")
    ]

    static let legJoints = ["leftHip", "leftKnee", "leftAnkle", "rightHip", "rightKnee", "rightAnkle"]
    /// (term, from joint, to joint): upper arm and forearm on each side, for the `shape.arm_weight` term.
    static let armBones: [(name: String, from: String, to: String)] = [
        ("leftUpperArm", "leftShoulder", "leftElbow"),
        ("leftForearm", "leftElbow", "leftWrist"),
        ("rightUpperArm", "rightShoulder", "rightElbow"),
        ("rightForearm", "rightElbow", "rightWrist")
    ]
    static let handSides = ["left", "right"]
    static let handSampleDeltas = [-0.12, 0.0, 0.12]

    static func swapMirrored(_ worldJoints: inout [String: Vec3]) {
        for (lName, rName) in mirrorSwapPairs {
            if let lVal = worldJoints[lName], let rVal = worldJoints[rName] {
                worldJoints[lName] = rVal
                worldJoints[rName] = lVal
            }
        }
    }

    /// One Euro smoothing of every 3D joint (body + foot) over a clip; timestamps, confidences and hands are kept.
    public static func smoothFrames(_ frames: [RawPoseFrame], config: SmoothingConfig) -> [RawPoseFrame] {
        var bank = OneEuro.LandmarkBank(minCutoff: config.min_cutoff, beta: config.beta, dCutoff: config.d_cutoff)
        return frames.map { frame in
            let valid = frame.joints.filter { $0.value.count >= 3 }
            var joints = frame.joints
            for (name, p) in bank.filter(joints: valid, t: frame.t) {
                joints[name] = p
            }
            return RawPoseFrame(t: frame.t, joints: joints, confidences: frame.confidences, hands: frame.hands)
        }
    }

    /// Learner time shift that phase-aligns a beat (same convention as the Shape score).
    static func beatShiftS(_ beat: BeatJudgment, audioLatencyMs: Double) -> Double {
        ((beat.judgment != "Miss") ? (beat.offset_ms / 1000.0) : 0.0) + (audioLatencyMs / 1000.0)
    }

    static func frameBracket(_ frames: [RawPoseFrame], _ tQuery: Double) -> (Int, Int, Double) {
        let last = frames.count - 1
        if tQuery <= frames[0].t { return (0, 0, 0.0) }
        if tQuery >= frames[last].t { return (last, last, 0.0) }
        for i in 0..<last {
            let t0 = frames[i].t
            let t1 = frames[i + 1].t
            if t0 <= tQuery && tQuery <= t1 {
                return (i, i + 1, (tQuery - t0) / max(1e-9, t1 - t0))
            }
        }
        return (last, last, 0.0)
    }

    /// Joints at `tQuery` (linear interpolation), gravity-aligned, mirrored like the attempt, root-centred and divided
    /// by leg length so poses of different dancers and camera distances are comparable. Root is omitted.
    public static func bodyNormalizedPose(
        frames: [RawPoseFrame],
        at tQuery: Double,
        gravityVector: Vec3,
        mirror: Bool = false
    ) -> [String: [Double]] {
        guard !frames.isEmpty else { return [:] }
        let (i0, i1, alpha) = frameBracket(frames, tQuery)
        let a = frames[i0].joints
        let b = frames[i1].joints
        var world: [String: Vec3] = [:]
        for (name, pa) in a {
            guard let pb = b[name], pa.count >= 3, pb.count >= 3 else { continue }
            var p = Vec3(
                (1.0 - alpha) * pa[0] + alpha * pb[0],
                (1.0 - alpha) * pa[1] + alpha * pb[1],
                (1.0 - alpha) * pa[2] + alpha * pb[2]
            )
            p = applyGravityCorrection(point: p, gravityVector: gravityVector)
            if mirror { p = Vec3(-p.x, p.y, p.z) }
            world[name] = p
        }
        if mirror { swapMirrored(&world) }
        guard let root = world["root"] else { return [:] }
        var scale = 1.0
        if legJoints.allSatisfy({ world[$0] != nil }),
           let lh = world["leftHip"], let lk = world["leftKnee"], let la = world["leftAnkle"],
           let rh = world["rightHip"], let rk = world["rightKnee"], let ra = world["rightAnkle"] {
            scale = max(0.4, 0.5 * (((lk - lh).norm + (la - lk).norm) + ((rk - rh).norm + (ra - rk).norm)))
        }
        var out: [String: [Double]] = [:]
        for (name, p) in world where name != "root" {
            out[name] = [(p.x - root.x) / scale, (p.y - root.y) / scale, (p.z - root.z) / scale]
        }
        return out
    }

    /// Unit upper-arm / forearm directions in the torso frame of a `bodyNormalizedPose` pose (root at origin).
    /// Torso frame (Gram-Schmidt): e1 = hip left -> right, e2 = root -> centerShoulder made orthogonal to e1,
    /// e3 = e1 x e2, which cancels the dancer's torso yaw. nil when the hips or centerShoulder are missing or the frame
    /// is degenerate; bones with a missing joint are left out.
    public static func torsoFrameArmVectors(_ pose: [String: [Double]]) -> [String: Vec3]? {
        guard let lh = pose["leftHip"], let rh = pose["rightHip"], let cs = pose["centerShoulder"],
              lh.count >= 3, rh.count >= 3, cs.count >= 3 else { return nil }
        let e1 = Vec3(rh[0] - lh[0], rh[1] - lh[1], rh[2] - lh[2]).normalized
        let up = Vec3(cs[0], cs[1], cs[2])
        let proj = Vec3.dot(up, e1)
        let e2 = Vec3(up.x - e1.x * proj, up.y - e1.y * proj, up.z - e1.z * proj).normalized
        guard e1.norm >= 0.5, e2.norm >= 0.5 else { return nil }
        let e3 = Vec3.cross(e1, e2)
        var out: [String: Vec3] = [:]
        for bone in armBones {
            guard let a = pose[bone.from], let b = pose[bone.to], a.count >= 3, b.count >= 3 else { continue }
            let v = Vec3(b[0] - a[0], b[1] - a[1], b[2] - a[2])
            out[bone.name] = Vec3(Vec3.dot(v, e1), Vec3.dot(v, e2), Vec3.dot(v, e3)).normalized
        }
        return out
    }

    // MARK: - Windows, velocity and occlusion

    /// The windows covering time t (start_s <= t < end_s), in order.
    static func windowsAt(_ windows: [ScoringWindow], _ t: Double) -> [ScoringWindow] {
        windows.filter { $0.start_s <= t && t < $0.end_s }
    }

    static func nearestFrameIndex(_ frames: [RawPoseFrame], _ tQuery: Double) -> Int {
        var best = 0
        var bestD = Double.infinity
        for (i, f) in frames.enumerated() {
            let d = abs(f.t - tQuery)
            if d < bestD {
                bestD = d
                best = i
            }
        }
        return best
    }

    /// Velocity tolerance factors (positions, angles) at tRef: min(max_factor, 1 + alpha * |omega_j(t)|). omega_j (rad/s)
    /// comes from body-normalised reference poses at tRef -/+ h: for a joint position, the turn rate of the bone that
    /// ends at it (its `Retarget.canonicalBones` parent -> joint); for a joint angle, that angle's rate of change.
    static func referenceVelocityFactors(
        refFrames: [RawPoseFrame],
        tRef: Double,
        refGravity: Vec3,
        config: ToleranceConfig
    ) -> ([String: Double], [String: Double]) {
        let alpha = config.velocity_scale
        let cap = config.velocity_max_factor
        let h = config.velocity_half_window_s
        var pos: [String: Double] = [:]
        var ang: [String: Double] = [:]
        guard h > 0.0 else { return (pos, ang) }
        let before = bodyNormalizedPose(frames: refFrames, at: tRef - h, gravityVector: refGravity, mirror: false)
        let after = bodyNormalizedPose(frames: refFrames, at: tRef + h, gravityVector: refGravity, mirror: false)
        let origin = [0.0, 0.0, 0.0]
        for bone in Retarget.canonicalBones {
            let parentBefore: [Double]? = bone.parent == "root" ? origin : before[bone.parent]
            let parentAfter: [Double]? = bone.parent == "root" ? origin : after[bone.parent]
            guard let c0 = before[bone.child], let c1 = after[bone.child],
                  let p0 = parentBefore, let p1 = parentAfter else { continue }
            let b0 = Vec3(c0[0] - p0[0], c0[1] - p0[1], c0[2] - p0[2])
            let b1 = Vec3(c1[0] - p1[0], c1[1] - p1[1], c1[2] - p1[2])
            if b0.norm < 1e-9 || b1.norm < 1e-9 { continue }
            let omega = angleBetweenRad(b0, b1) / (2.0 * h)
            pos[bone.child] = min(cap, 1.0 + alpha * omega)
        }
        let beforeFrame = JointTolerance.RawFrame(joints: before)
        let afterFrame = JointTolerance.RawFrame(joints: after)
        for triple in JointTolerance.defaultAngleTriples {
            guard let a0 = JointTolerance.angleDeg(beforeFrame, triple),
                  let a1 = JointTolerance.angleDeg(afterFrame, triple) else { continue }
            let omega = (abs(a1 - a0) / (2.0 * h)) * .pi / 180.0
            ang[triple.name] = min(cap, 1.0 + alpha * omega)
        }
        return (pos, ang)
    }

    /// Joints (of `names`) occluded on this beat; a joint angle (knee, elbow) is occluded, under its name, when any of
    /// its three joints is. See `OcclusionConfig`.
    static func occludedJoints(
        names: [String],
        refFrames: [RawPoseFrame],
        userFrames: [RawPoseFrame],
        tRef: Double,
        tUsr: Double,
        refPose: [String: [Double]],
        usrPose: [String: [Double]],
        mirror: Bool,
        config: OcclusionConfig
    ) -> Set<String> {
        let refConf = refFrames[nearestFrameIndex(refFrames, tRef)].confidences ?? [:]
        let usrConf = userFrames[nearestFrameIndex(userFrames, tUsr)].confidences ?? [:]
        var close = false
        if config.wrist_distance > 0.0 {
            for pose in [refPose, usrPose] {
                if let lw = pose["leftWrist"], let rw = pose["rightWrist"],
                   Vec3(lw[0] - rw[0], lw[1] - rw[1], lw[2] - rw[2]).norm < config.wrist_distance {
                    close = true
                }
            }
        }
        let wristsClose = close
        func occluded(_ name: String) -> Bool {
            let rc = refConf[name] ?? 1.0
            let uc = usrConf[mirror ? Retarget.mirrorName(name) : name] ?? 1.0
            return min(rc, uc) < config.min_confidence || (wristsClose && (name == "leftWrist" || name == "rightWrist"))
        }
        var out = Set(names.filter { occluded($0) })
        for triple in JointTolerance.defaultAngleTriples where !out.contains(triple.name) {
            if occluded(triple.parent) || occluded(triple.joint) || occluded(triple.child) {
                out.insert(triple.name)
            }
        }
        return out
    }

    // MARK: - Hit timing

    static func hitJudgment(_ offsetMs: Double, perfectMs: Double, goodMs: Double) -> String {
        if abs(offsetMs) <= perfectMs { return "Perfect" }
        if abs(offsetMs) <= goodMs { return "Good" }
        return offsetMs < 0 ? "Early" : "Late"
    }

    /// Index into `beats` -> hit offset (ms); when several hits pair to one beat the closest wins (first on ties).
    static func pairedOffsetsByBeat(_ pairs: [MoveSegmenter.BeatPair], beats: [Double]) -> [Int: Double] {
        var out: [Int: Double] = [:]
        for pair in pairs {
            guard let idx = beats.firstIndex(of: pair.beatTimestamp) else { continue }
            if let existing = out[idx], !(abs(pair.offsetMs) < abs(existing)) { continue }
            out[idx] = pair.offsetMs
        }
        return out
    }

    /// Accent / hit timing: the learner's settle-after-move hits vs the reference's hits on the same beats.
    /// Offsets are relative to the reference's hit moment (beat + reference settle offset), so choreography that
    /// settles slightly after the beat is not penalised. A reference without hits (continuous grooves) is
    /// `not_applicable`; a reference hit the learner does not reproduce is a Miss.
    public static func scoreHitTiming(
        userFrames: [RawPoseFrame],
        refFrames: [RawPoseFrame],
        beatTimes: [Double],
        audioLatencyMs: Double,
        config: HitTimingConfig
    ) -> HitTimingResult {
        guard config.enabled else {
            return HitTimingResult(status: "disabled", hit_score: nil, reference_hit_count: 0, user_hit_count: 0,
                                   matched_count: 0, on_beat_ratio: nil, mean_offset_ms: nil, per_hit: [])
        }
        let segCfg = config.segmenterConfig
        let refHits = MoveSegmenter.detectHits(frames: refFrames, config: segCfg)
        let userHits = MoveSegmenter.detectHits(frames: userFrames, config: segCfg)
        let latencyS = audioLatencyMs / 1000.0
        let userShifted = userHits.map {
            MoveSegmenter.HitEvent(timestamp: $0.timestamp - latencyS, peakSpeed: $0.peakSpeed, settleDuration: $0.settleDuration)
        }
        let refByBeat = pairedOffsetsByBeat(
            MoveSegmenter.pairHitsToBeats(hits: refHits, beats: beatTimes, toleranceMs: config.beat_tolerance_ms),
            beats: beatTimes
        )
        guard !refByBeat.isEmpty else {
            return HitTimingResult(status: "not_applicable", hit_score: nil, reference_hit_count: refHits.count,
                                   user_hit_count: userHits.count, matched_count: 0, on_beat_ratio: nil,
                                   mean_offset_ms: nil, per_hit: [])
        }

        let hitBeats = refByBeat.keys.sorted()
        let expected = hitBeats.map { beatTimes[$0] + (refByBeat[$0] ?? 0.0) / 1000.0 }
        let userBySlot = pairedOffsetsByBeat(
            MoveSegmenter.pairHitsToBeats(hits: userShifted, beats: expected, toleranceMs: config.beat_tolerance_ms),
            beats: expected
        )

        var perHit: [HitJudgment] = []
        var offsets: [Double] = []
        var credit = 0.0
        var onBeat = 0
        for (slot, idx) in hitBeats.enumerated() {
            guard let off = userBySlot[slot] else {
                perHit.append(HitJudgment(count_number: idx + 1, offset_ms: nil, judgment: "Miss"))
                continue
            }
            let judgment = hitJudgment(off, perfectMs: config.perfect_max_ms, goodMs: config.good_max_ms)
            if judgment == "Perfect" || judgment == "Good" { onBeat += 1 }
            let excess = max(0.0, abs(off) - config.perfect_max_ms) / max(1.0, config.beat_tolerance_ms - config.perfect_max_ms)
            credit += max(0.0, min(1.0, 1.0 - excess))
            offsets.append(off)
            perHit.append(HitJudgment(count_number: idx + 1, offset_ms: roundTo(off, places: 2), judgment: judgment))
        }

        let n = Double(hitBeats.count)
        return HitTimingResult(
            status: "available",
            hit_score: roundTo(100.0 * credit / n, places: 2),
            reference_hit_count: refHits.count,
            user_hit_count: userHits.count,
            matched_count: offsets.count,
            on_beat_ratio: roundTo(Double(onBeat) / n, places: 3),
            mean_offset_ms: offsets.isEmpty ? nil : roundTo(offsets.reduce(0, +) / Double(offsets.count), places: 2),
            per_hit: perHit
        )
    }

    // MARK: - Joint tolerance verdicts

    /// Per-joint position + angle tolerances from golden performances. Every beat of every golden clip is one aligned
    /// sample (a looped move repeats its pose each count), so a single reference already yields a spread; extra
    /// clean takes widen it to the dancer's natural variation.
    public static func computeJointTolerances(
        clips: [PoseClip],
        beatTimes: [Double],
        config: JointToleranceThresholds,
        smoothing: SmoothingConfig? = nil
    ) -> JointTolerances {
        var samples: [JointTolerance.RawFrame] = []
        for clip in clips {
            var frames = clip.frames
            if let smoothing, smoothing.enabled {
                frames = smoothFrames(frames, config: smoothing)
            }
            let gravity = Vec3(array: clip.gravity_vector ?? [0.0, -1.0, 0.0])
            let latencyS = (clip.audio_latency_ms ?? 0.0) / 1000.0
            let mirror = clip.mirrored ?? false
            for b in beatTimes {
                let pose = bodyNormalizedPose(frames: frames, at: b + latencyS, gravityVector: gravity, mirror: mirror)
                if !pose.isEmpty { samples.append(JointTolerance.RawFrame(joints: pose)) }
            }
        }
        let moduleCfg = config.moduleConfig
        return JointTolerances(
            positions: JointTolerance.positionTolerances(references: samples, config: moduleCfg),
            angles: JointTolerance.angleTolerances(references: samples, config: moduleCfg)
        )
    }

    /// Per-joint ok/warn/off verdicts with correction hints, averaged over the phase-aligned beats. Severity uses the
    /// mean per-beat error vs the golden tolerance; the hint follows the mean learner -> reference displacement
    /// (positions) or the mean signed angle difference (knees / elbows).
    ///
    /// Each beat's error is divided by that joint's tolerance scale on the beat: the product of every covering window's
    /// `tolerance_scale`, the velocity factor and, when occluded, the occlusion factor. With `occlusion.mask` an
    /// occluded joint's beat is left out. All scales default to 1, so `error` is then the plain mean error.
    public static func scoreJointFeedback(
        userFrames: [RawPoseFrame],
        refFrames: [RawPoseFrame],
        beatTimes: [Double],
        perBeat: [BeatJudgment],
        audioLatencyMs: Double,
        userGravity: Vec3,
        refGravity: Vec3,
        mirror: Bool,
        tolerances: JointTolerances,
        config: JointToleranceThresholds,
        windows: [ScoringWindow] = [],
        tolerance: ToleranceConfig = ToleranceConfig()
    ) -> JointFeedbackResult {
        let emptyCounts = ["ok": 0, "warn": 0, "off": 0]
        guard config.enabled else {
            return JointFeedbackResult(status: "disabled", verdicts: [], angle_verdicts: [], top_joint: nil,
                                       top_hint: nil, counts: emptyCounts)
        }
        let posNames = tolerances.positions.keys.sorted()
        let velocityOn = tolerance.velocity_scale != 0.0
        let occFactor = tolerance.occlusion.factor
        let occMask = tolerance.occlusion.mask
        let occlusionOn = occMask || occFactor != 1.0
        let occNames = Set(posNames + JointTolerance.defaultAngleTriples.map { $0.name }).sorted()
        var posErr: [String: [Double]] = [:]
        var posDelta: [String: Vec3] = [:]
        var angErr: [String: [Double]] = [:]
        var angSigned: [String: Double] = [:]

        for (idx, bTime) in beatTimes.enumerated() {
            let tUsr = bTime + beatShiftS(perBeat[idx], audioLatencyMs: audioLatencyMs)
            let refPose = bodyNormalizedPose(frames: refFrames, at: bTime, gravityVector: refGravity, mirror: false)
            let usrPose = bodyNormalizedPose(frames: userFrames, at: tUsr, gravityVector: userGravity, mirror: mirror)
            guard !refPose.isEmpty, !usrPose.isEmpty else { continue }
            let active = windowsAt(windows, bTime)
            let (velPos, velAng): ([String: Double], [String: Double]) = velocityOn
                ? referenceVelocityFactors(refFrames: refFrames, tRef: bTime, refGravity: refGravity, config: tolerance)
                : ([:], [:])
            let occluded: Set<String> = occlusionOn
                ? occludedJoints(names: occNames, refFrames: refFrames, userFrames: userFrames, tRef: bTime, tUsr: tUsr,
                                 refPose: refPose, usrPose: usrPose, mirror: mirror, config: tolerance.occlusion)
                : []
            func scale(_ name: String, _ velocity: [String: Double]) -> Double {
                var s = 1.0
                for w in active {
                    if let f = w.tolerance_scale?[name] { s *= f }
                }
                if let v = velocity[name] { s *= v }
                if occluded.contains(name) { s *= occFactor }
                return s
            }

            for name in posNames {
                guard let r = refPose[name], let u = usrPose[name] else { continue }
                if occMask && occluded.contains(name) { continue }
                let d = Vec3(r[0] - u[0], r[1] - u[1], r[2] - u[2])
                let err = (d.x * d.x + d.y * d.y + d.z * d.z).squareRoot()
                posErr[name, default: []].append(err / scale(name, velPos))
                let acc = posDelta[name] ?? Vec3(0, 0, 0)
                posDelta[name] = Vec3(acc.x + d.x, acc.y + d.y, acc.z + d.z)
            }
            let refFrame = JointTolerance.RawFrame(joints: refPose)
            let usrFrame = JointTolerance.RawFrame(joints: usrPose)
            for triple in JointTolerance.defaultAngleTriples where tolerances.angles[triple.name] != nil {
                if occMask && occluded.contains(triple.name) { continue }
                guard let ra = JointTolerance.angleDeg(refFrame, triple),
                      let ua = JointTolerance.angleDeg(usrFrame, triple) else { continue }
                angErr[triple.name, default: []].append(abs(ua - ra) / scale(triple.name, velAng))
                angSigned[triple.name, default: 0.0] += (ra - ua)
            }
        }

        var ratios: [(Double, JointVerdictSummary)] = []
        var verdicts: [JointVerdictSummary] = []
        for name in posErr.keys.sorted() {
            guard let errs = posErr[name], let tol = tolerances.positions[name] else { continue }
            let err = errs.reduce(0, +) / Double(errs.count)
            let sev = JointTolerance.severity(err, tol, config.warn_factor)
            let hint = sev == .ok ? nil : JointTolerance.hint(name, posDelta[name] ?? Vec3(0, 0, 0))
            let v = JointVerdictSummary(joint: name, error: roundTo(err, places: 4), tolerance: roundTo(tol, places: 4),
                                        severity: sev.rawValue, hint: hint)
            verdicts.append(v)
            ratios.append((err / tol, v))
        }
        var angleVerdicts: [JointVerdictSummary] = []
        for name in angErr.keys.sorted() {
            guard let errs = angErr[name], let tol = tolerances.angles[name] else { continue }
            let err = errs.reduce(0, +) / Double(errs.count)
            let sev = JointTolerance.severity(err, tol, config.warn_factor)
            let hint = sev == .ok ? nil : (((angSigned[name] ?? 0.0) > 0 ? "open " : "bend ") + JointTolerance.words(name))
            let v = JointVerdictSummary(joint: name, error: roundTo(err, places: 3), tolerance: roundTo(tol, places: 3),
                                        severity: sev.rawValue, hint: hint)
            angleVerdicts.append(v)
            ratios.append((err / tol, v))
        }

        var top: (Double, JointVerdictSummary)? = nil
        var counts = emptyCounts
        for (ratio, v) in ratios {
            counts[v.severity, default: 0] += 1
            if v.severity != "ok", top == nil || ratio > (top?.0 ?? 0.0) {
                top = (ratio, v)
            }
        }
        return JointFeedbackResult(
            status: verdicts.isEmpty ? "unavailable" : "available",
            verdicts: verdicts,
            angle_verdicts: angleVerdicts,
            top_joint: top?.1.joint,
            top_hint: top?.1.hint,
            counts: counts
        )
    }

    // MARK: - Hand styling

    /// Hand landmarks of the frame nearest `tQuery` ("left" / "right" -> 21 points), mirrored like the body.
    static func hands(frames: [RawPoseFrame], at tQuery: Double, mirror: Bool) -> [String: [Vec3]] {
        var best = 0
        var bestD = Double.infinity
        for (i, f) in frames.enumerated() {
            let d = abs(f.t - tQuery)
            if d < bestD {
                bestD = d
                best = i
            }
        }
        let frameHands = frames[best].hands ?? [:]
        var out: [String: [Vec3]] = [:]
        for side in handSides {
            guard let pts = frameHands[side], pts.count == HandStyling.landmarkCount else { continue }
            let sign = mirror ? -1.0 : 1.0
            let target = mirror ? (side == "left" ? "right" : "left") : side
            out[target] = pts.map { p in
                Vec3(sign * (p.count > 0 ? p[0] : 0.0), p.count > 1 ? p[1] : 0.0, p.count > 2 ? p[2] : 0.0)
            }
        }
        return out
    }

    static func majorityLabel(_ labels: [String]) -> String? {
        var best: String? = nil
        var bestN = 0
        for shape in HandStyling.Shape.allCases {
            let n = labels.filter { $0 == shape.rawValue }.count
            if n > bestN {
                best = shape.rawValue
                bestN = n
            }
        }
        return best
    }

    /// Hand-shape similarity (0-100) vs the reference at the phase-aligned beat samples. Only hands present in both
    /// learner and reference frames count; with no such sample the component is `skipped` (never scored as zero).
    /// Samples inside a window whose `mask` lists "hand_shape" are left out and counted in `masked_samples`.
    public static func scoreHandStyling(
        userFrames: [RawPoseFrame],
        refFrames: [RawPoseFrame],
        beatTimes: [Double],
        perBeat: [BeatJudgment],
        audioLatencyMs: Double,
        mirror: Bool,
        config: HandStylingThresholds,
        windows: [ScoringWindow] = []
    ) -> HandStylingResult {
        guard config.enabled else {
            return HandStylingResult(status: "disabled", hand_score: nil, samples: 0, masked_samples: 0, user_shape: nil, reference_shape: nil)
        }
        guard !userFrames.isEmpty, !refFrames.isEmpty else {
            return HandStylingResult(status: "skipped", hand_score: nil, samples: 0, masked_samples: 0, user_shape: nil, reference_shape: nil)
        }
        let masks = windows.filter { $0.mask?.contains("hand_shape") ?? false }
        var sims: [Double] = []
        var userLabels: [String] = []
        var refLabels: [String] = []
        var masked = 0
        for (idx, bTime) in beatTimes.enumerated() {
            let shift = beatShiftS(perBeat[idx], audioLatencyMs: audioLatencyMs)
            for delta in handSampleDeltas {
                let tRef = bTime + delta
                if !windowsAt(masks, tRef).isEmpty {
                    masked += 1
                    continue
                }
                let refHands = hands(frames: refFrames, at: tRef, mirror: false)
                let usrHands = hands(frames: userFrames, at: tRef + shift, mirror: mirror)
                for side in handSides {
                    guard let rp = refHands[side], let up = usrHands[side],
                          let rf = HandStyling.extractFeatures(points: rp, isLeft: side == "left"),
                          let uf = HandStyling.extractFeatures(points: up, isLeft: side == "left") else { continue }
                    sims.append(HandStyling.compare(uf, rf))
                    userLabels.append(HandStyling.classify(uf).label.rawValue)
                    refLabels.append(HandStyling.classify(rf).label.rawValue)
                }
            }
        }
        guard !sims.isEmpty else {
            return HandStylingResult(status: "skipped", hand_score: nil, samples: 0, masked_samples: masked, user_shape: nil, reference_shape: nil)
        }
        return HandStylingResult(
            status: "available",
            hand_score: roundTo(sims.reduce(0, +) / Double(sims.count), places: 2),
            samples: sims.count,
            masked_samples: masked,
            user_shape: majorityLabel(userLabels),
            reference_shape: majorityLabel(refLabels)
        )
    }

    // MARK: - Top issue

    private static func pct(_ ratio: Double) -> String {
        String(format: "%.0f%%", ratio * 100.0)
    }

    private static func signedMs(_ ms: Double) -> String {
        String(format: "%+.0f", ms)
    }

    static func describeTopIssue(
        coverageOk: Bool, timingOk: Bool, shapeOk: Bool, grooveOk: Bool,
        hitsOk: Bool, handsOk: Bool,
        footScoringStatus: String, footCoverageRatio: Double, coverageRatio: Double,
        worstBeat: BeatJudgment, worstJoint: JointErrorSummary?,
        goodOrBetterRatio: Double, kneeFlexRatio: Double, spineLagMs: Double,
        hitTiming: HitTimingResult, handStyling: HandStylingResult, timingSource: String = "bounce"
    ) -> String {
        let joint = worstJoint?.joint ?? "knees"
        let jointErr = worstJoint?.mean_angle_error_deg ?? 0.0
        if !coverageOk {
            if footScoringStatus == "unavailable" {
                return "Foot keypoints unavailable (foot coverage \(pct(footCoverageRatio))); real foot landmarker required to score footwork."
            }
            return "Low tracking coverage (\(pct(coverageRatio))); step back so head and feet stay in frame."
        }
        if !shapeOk {
            return "Shape error on \(joint) (avg \(String(format: "%.1f", jointErr)) deg off, worst timing at count \(worstBeat.count_number) by \(signedMs(worstBeat.offset_ms)) ms)."
        }
        if !timingOk && timingSource == "hits" {
            let landed = hitTiming.per_hit.filter { $0.judgment == "Perfect" || $0.judgment == "Good" }.count
            return "Hit timing off: \(landed)/\(hitTiming.per_hit.count) accents on the beat."
        }
        if !timingOk {
            return "Timing \(worstBeat.judgment.lowercased()) on count \(worstBeat.count_number) by \(signedMs(worstBeat.offset_ms)) ms (primary joint: \(joint))."
        }
        if !grooveOk {
            return "Stiff groove (knee flex \(pct(kneeFlexRatio)) of ref, spine lag \(String(format: "%.0f", spineLagMs)) ms, count \(worstBeat.count_number) offset \(signedMs(worstBeat.offset_ms)) ms)."
        }
        if !hitsOk {
            return "Hits off the beat (hit score \(String(format: "%.0f", hitTiming.hit_score ?? 0.0)), \(hitTiming.matched_count)/\(hitTiming.per_hit.count) accents landed)."
        }
        if !handsOk {
            return "Hand styling off (\(handStyling.user_shape ?? "unknown") vs \(handStyling.reference_shape ?? "unknown"), score \(String(format: "%.0f", handStyling.hand_score ?? 0.0)))."
        }
        if timingSource == "hits" && hitTiming.status == "available" {
            return "Clean pass: \(pct(hitTiming.on_beat_ratio ?? 0.0)) of accents on the beat."
        }
        return "Clean pass: \(pct(goodOrBetterRatio)) beats Good+, count \(worstBeat.count_number) within \(signedMs(worstBeat.offset_ms)) ms."
    }
}
