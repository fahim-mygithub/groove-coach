import Foundation

/// Wave-2 scoring components wired into `GrooveScoringEngine.scoreAttempt`, numeric mirror of `groove_eval/scoring.py`:
/// 1. One Euro smoothing of body + foot keypoints before feature extraction (`smoothing`).
/// 2. Hit timing: settle-after-move hits (`MoveSegmenter`) vs the reference's hits on the same beats (`hits`).
/// 3. Per-joint ok/warn/off verdicts + correction hints from golden-performance tolerances (`joint_tolerance`).
/// 4. Hand styling score when hand landmarks are present; absent hands skip the component (`hands`).
/// New components report but never gate `passed` unless their `gate` flag is set.
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
        config: JointToleranceThresholds
    ) -> JointFeedbackResult {
        let emptyCounts = ["ok": 0, "warn": 0, "off": 0]
        guard config.enabled else {
            return JointFeedbackResult(status: "disabled", verdicts: [], angle_verdicts: [], top_joint: nil,
                                       top_hint: nil, counts: emptyCounts)
        }
        let posNames = tolerances.positions.keys.sorted()
        var posErr: [String: [Double]] = [:]
        var posDelta: [String: Vec3] = [:]
        var angErr: [String: [Double]] = [:]
        var angSigned: [String: Double] = [:]

        for (idx, bTime) in beatTimes.enumerated() {
            let tUsr = bTime + beatShiftS(perBeat[idx], audioLatencyMs: audioLatencyMs)
            let refPose = bodyNormalizedPose(frames: refFrames, at: bTime, gravityVector: refGravity, mirror: false)
            let usrPose = bodyNormalizedPose(frames: userFrames, at: tUsr, gravityVector: userGravity, mirror: mirror)
            guard !refPose.isEmpty, !usrPose.isEmpty else { continue }
            for name in posNames {
                guard let r = refPose[name], let u = usrPose[name] else { continue }
                let d = Vec3(r[0] - u[0], r[1] - u[1], r[2] - u[2])
                posErr[name, default: []].append((d.x * d.x + d.y * d.y + d.z * d.z).squareRoot())
                let acc = posDelta[name] ?? Vec3(0, 0, 0)
                posDelta[name] = Vec3(acc.x + d.x, acc.y + d.y, acc.z + d.z)
            }
            let refFrame = JointTolerance.RawFrame(joints: refPose)
            let usrFrame = JointTolerance.RawFrame(joints: usrPose)
            for triple in JointTolerance.defaultAngleTriples where tolerances.angles[triple.name] != nil {
                guard let ra = JointTolerance.angleDeg(refFrame, triple),
                      let ua = JointTolerance.angleDeg(usrFrame, triple) else { continue }
                angErr[triple.name, default: []].append(abs(ua - ra))
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
    public static func scoreHandStyling(
        userFrames: [RawPoseFrame],
        refFrames: [RawPoseFrame],
        beatTimes: [Double],
        perBeat: [BeatJudgment],
        audioLatencyMs: Double,
        mirror: Bool,
        config: HandStylingThresholds
    ) -> HandStylingResult {
        guard config.enabled else {
            return HandStylingResult(status: "disabled", hand_score: nil, samples: 0, user_shape: nil, reference_shape: nil)
        }
        guard !userFrames.isEmpty, !refFrames.isEmpty else {
            return HandStylingResult(status: "skipped", hand_score: nil, samples: 0, user_shape: nil, reference_shape: nil)
        }
        var sims: [Double] = []
        var userLabels: [String] = []
        var refLabels: [String] = []
        for (idx, bTime) in beatTimes.enumerated() {
            let shift = beatShiftS(perBeat[idx], audioLatencyMs: audioLatencyMs)
            for delta in handSampleDeltas {
                let tRef = bTime + delta
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
            return HandStylingResult(status: "skipped", hand_score: nil, samples: 0, user_shape: nil, reference_shape: nil)
        }
        return HandStylingResult(
            status: "available",
            hand_score: roundTo(sims.reduce(0, +) / Double(sims.count), places: 2),
            samples: sims.count,
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
        hitTiming: HitTimingResult, handStyling: HandStylingResult
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
        return "Clean pass: \(pct(goodOrBetterRatio)) beats Good+, count \(worstBeat.count_number) within \(signedMs(worstBeat.offset_ms)) ms."
    }
}
