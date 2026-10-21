import Foundation

/// Pure-math deterministic scoring engine for Groove Coach.
/// Free of Apple-only frameworks (`Vision`, `AVFoundation`, `CoreMotion`) so it compiles and tests
/// natively on Linux CI (`swift test`) with 100% numeric parity to `groove_eval/scoring.py`,
/// while running directly inside the iOS 17+ app in real time.
public enum GrooveScoringEngine {

    public struct Vec3: Sendable, Codable, Equatable {
        public var x: Double
        public var y: Double
        public var z: Double

        public init(_ x: Double, _ y: Double, _ z: Double) {
            self.x = x
            self.y = y
            self.z = z
        }

        public init(array: [Double]) {
            self.x = array.count > 0 ? array[0] : 0.0
            self.y = array.count > 1 ? array[1] : 0.0
            self.z = array.count > 2 ? array[2] : 0.0
        }

        public var norm: Double {
            (x * x + y * y + z * z).squareRoot()
        }

        public var normalized: Vec3 {
            let n = norm
            guard n >= 1e-9 else { return Vec3(0.0, 0.0, 0.0) }
            return Vec3(x / n, y / n, z / n)
        }

        public static func - (lhs: Vec3, rhs: Vec3) -> Vec3 {
            Vec3(lhs.x - rhs.x, lhs.y - rhs.y, lhs.z - rhs.z)
        }

        public static func + (lhs: Vec3, rhs: Vec3) -> Vec3 {
            Vec3(lhs.x + rhs.x, lhs.y + rhs.y, lhs.z + rhs.z)
        }

        public static func * (lhs: Vec3, rhs: Double) -> Vec3 {
            Vec3(lhs.x * rhs, lhs.y * rhs, lhs.z * rhs)
        }

        public static func dot(_ a: Vec3, _ b: Vec3) -> Double {
            a.x * b.x + a.y * b.y + a.z * b.z
        }

        public static func cross(_ a: Vec3, _ b: Vec3) -> Vec3 {
            Vec3(
                a.y * b.z - a.z * b.y,
                a.z * b.x - a.x * b.z,
                a.x * b.y - a.y * b.x
            )
        }
    }

    public static let requiredBodyJoints: [String] = [
        "root", "spine", "centerShoulder",
        "leftHip", "leftKnee", "leftAnkle",
        "rightHip", "rightKnee", "rightAnkle",
        "leftShoulder", "rightShoulder"
    ]

    public static let requiredFootJoints: [String] = [
        "leftHeel", "leftFootIndex", "rightHeel", "rightFootIndex"
    ]

    public static let requiredJoints: [String] = requiredBodyJoints + requiredFootJoints

    // MARK: - Config Models

    public struct TimingThresholds: Sendable, Codable {
        public let perfect_max_ms: Double
        public let good_max_ms: Double
        public let search_window_beats: Double

        public init(perfect_max_ms: Double, good_max_ms: Double, search_window_beats: Double) {
            self.perfect_max_ms = perfect_max_ms
            self.good_max_ms = good_max_ms
            self.search_window_beats = search_window_beats
        }
    }

    public struct ShapeThresholds: Sendable, Codable {
        public let max_angle_error_deg: Double
        public let max_single_joint_error_deg: Double
        public let foot_pitch_weight: Double
        public let pass_min_score: Double

        public init(max_angle_error_deg: Double, max_single_joint_error_deg: Double, foot_pitch_weight: Double, pass_min_score: Double) {
            self.max_angle_error_deg = max_angle_error_deg
            self.max_single_joint_error_deg = max_single_joint_error_deg
            self.foot_pitch_weight = foot_pitch_weight
            self.pass_min_score = pass_min_score
        }
    }

    public struct GrooveThresholds: Sendable, Codable {
        public let min_knee_flex_ratio: Double
        public let ideal_spine_lag_ms_min: Double
        public let ideal_spine_lag_ms_max: Double
        public let max_jerk_ratio: Double
        public let pass_min_score: Double

        public init(min_knee_flex_ratio: Double, ideal_spine_lag_ms_min: Double, ideal_spine_lag_ms_max: Double, max_jerk_ratio: Double, pass_min_score: Double) {
            self.min_knee_flex_ratio = min_knee_flex_ratio
            self.ideal_spine_lag_ms_min = ideal_spine_lag_ms_min
            self.ideal_spine_lag_ms_max = ideal_spine_lag_ms_max
            self.max_jerk_ratio = max_jerk_ratio
            self.pass_min_score = pass_min_score
        }
    }

    public struct CoverageThresholds: Sendable, Codable {
        public let min_joint_confidence: Double
        public let min_valid_frame_ratio: Double

        public init(min_joint_confidence: Double, min_valid_frame_ratio: Double) {
            self.min_joint_confidence = min_joint_confidence
            self.min_valid_frame_ratio = min_valid_frame_ratio
        }
    }

    public struct GateThresholds: Sendable, Codable {
        public let min_good_or_better_beat_ratio: Double
        public let speed_ladder_pct: [Int]

        public init(min_good_or_better_beat_ratio: Double, speed_ladder_pct: [Int]) {
            self.min_good_or_better_beat_ratio = min_good_or_better_beat_ratio
            self.speed_ladder_pct = speed_ladder_pct
        }
    }

    public struct ScoringThresholds: Sendable, Codable {
        public let timing: TimingThresholds
        public let shape: ShapeThresholds
        public let groove: GrooveThresholds
        public let coverage: CoverageThresholds
        public let gate: GateThresholds

        public init(timing: TimingThresholds, shape: ShapeThresholds, groove: GrooveThresholds, coverage: CoverageThresholds, gate: GateThresholds) {
            self.timing = timing
            self.shape = shape
            self.groove = groove
            self.coverage = coverage
            self.gate = gate
        }
    }

    public struct GrooveConfig: Sendable, Codable {
        public let version: String
        public let scoring_thresholds: ScoringThresholds

        public init(version: String, scoring_thresholds: ScoringThresholds) {
            self.version = version
            self.scoring_thresholds = scoring_thresholds
        }
    }

    // MARK: - Pose Clip Models

    public struct RawPoseFrame: Sendable, Codable {
        public let t: Double
        public let joints: [String: [Double]]
        public let confidences: [String: Double]?

        public init(t: Double, joints: [String: [Double]], confidences: [String: Double]? = nil) {
            self.t = t
            self.joints = joints
            self.confidences = confidences
        }
    }

    public struct ExpectedLabel: Sendable, Codable {
        public let passed: Bool
        public let reason: String?

        public init(passed: Bool, reason: String? = nil) {
            self.passed = passed
            self.reason = reason
        }
    }

    public struct PoseClip: Sendable, Codable {
        public let clip_id: String
        public let move_tag: String
        public let bpm: Double
        public let beat_times: [Double]
        public let gravity_vector: [Double]?
        public let mirrored: Bool?
        public let audio_latency_ms: Double?
        public let speed_pct: Int?
        public let expected: ExpectedLabel?
        public let frames: [RawPoseFrame]

        public init(
            clip_id: String,
            move_tag: String,
            bpm: Double,
            beat_times: [Double],
            gravity_vector: [Double]? = nil,
            mirrored: Bool? = false,
            audio_latency_ms: Double? = 0.0,
            speed_pct: Int? = 100,
            expected: ExpectedLabel? = nil,
            frames: [RawPoseFrame]
        ) {
            self.clip_id = clip_id
            self.move_tag = move_tag
            self.bpm = bpm
            self.beat_times = beat_times
            self.gravity_vector = gravity_vector
            self.mirrored = mirrored
            self.audio_latency_ms = audio_latency_ms
            self.speed_pct = speed_pct
            self.expected = expected
            self.frames = frames
        }
    }

    // MARK: - Output Models

    public struct FrameFeatures: Sendable, Codable {
        public let t: Double
        public let left_knee_flex: Double
        public let right_knee_flex: Double
        public let mean_knee_flex: Double
        public let spine_jack_angle: Double
        public let trunk_lean_deg: Double
        public let left_foot_pitch_deg: Double
        public let right_foot_pitch_deg: Double
        public let hip_height_norm: Double
        public let shoulder_height_norm: Double
        public let hip_x_norm: Double

        public func value(forKey key: String) -> Double {
            switch key {
            case "mean_knee_flex": return mean_knee_flex
            case "spine_jack_angle": return spine_jack_angle
            case "trunk_lean_deg": return trunk_lean_deg
            case "left_foot_pitch_deg": return left_foot_pitch_deg
            case "right_foot_pitch_deg": return right_foot_pitch_deg
            case "hip_height_norm": return hip_height_norm
            case "shoulder_height_norm": return shoulder_height_norm
            case "hip_x_norm": return hip_x_norm
            default: return 0.0
            }
        }
    }

    public struct BeatJudgment: Sendable, Codable {
        public let count_number: Int
        public let offset_ms: Double
        public let judgment: String
    }

    public struct JointErrorSummary: Sendable, Codable {
        public let joint: String
        public let mean_angle_error_deg: Double
    }

    public struct AttemptScoreResult: Sendable, Codable {
        public let clip_id: String
        public let passed: Bool
        public let coverage_ratio: Double
        public let foot_scoring_status: String
        public let mean_offset_ms: Double
        public let good_or_better_ratio: Double
        public let shape_score: Double
        public let groove_score: Double
        public let knee_flex_ratio: Double
        public let spine_lag_ms: Double
        public let worst_beat: BeatJudgment
        public let worst_joints: [JointErrorSummary]
    }

    public struct ClapSyncResult: Sendable, Codable, Equatable {
        public let synced: Bool
        public let offset_ms: Double
        public let visual_clap_host_time: Double?
    }

    public struct LearnerBaseline: Sendable, Codable {
        public let personal_leg_scale_m: Double
        public let baseline_timing_bias_ms: Double
        public let baseline_knee_flex_ratio: Double
        public let baseline_spine_lag_ms: Double
        public let baseline_groove_score: Double
        public let recommended_groove_gate: Double
    }

    public struct CalibrationClipResult: Sendable, Codable {
        public let clip_id: String
        public let expected_pass: Bool
        public let actual_pass: Bool
        public let matched: Bool
        public let mean_offset_ms: Double
        public let shape_score: Double
        public let groove_score: Double
        public let coverage_ratio: Double
    }

    public struct CalibrationReport: Sendable, Codable {
        public let calibration_valid: Bool
        public let total_clips: Int
        public let matched_clips: Int
        public let separation_accuracy: Double
        public let clean_pass_rate: Double
        public let negative_rejection_rate: Double
        public let learner_baseline: LearnerBaseline
        public let clip_results: [CalibrationClipResult]
    }

    // MARK: - Core Math Functions

    private static func roundTo(_ val: Double, places: Int) -> Double {
        let p = pow(10.0, Double(places))
        return (val * p).rounded() / p
    }

    public static func angleBetweenDeg(_ u: Vec3, _ v: Vec3) -> Double {
        let un = u.normalized
        let vn = v.normalized
        let cosVal = min(1.0, max(-1.0, Vec3.dot(un, vn)))
        return acos(cosVal) * 180.0 / .pi
    }

    public static func applyGravityCorrection(point: Vec3, gravityVector: Vec3) -> Vec3 {
        let g = gravityVector.normalized
        let target = Vec3(0.0, -1.0, 0.0)
        let cosTheta = min(1.0, max(-1.0, Vec3.dot(g, target)))
        if cosTheta > 0.999999 { return point }
        if cosTheta < -0.999999 { return Vec3(point.x, -point.y, -point.z) }

        let axis = Vec3.cross(g, target).normalized
        let sinTheta = max(0.0, 1.0 - cosTheta * cosTheta).squareRoot()
        let kDotP = Vec3.dot(axis, point)
        let kCrossP = Vec3.cross(axis, point)

        return point * cosTheta + kCrossP * sinTheta + axis * (kDotP * (1.0 - cosTheta))
    }

    public static func extractFrameFeatures(
        frame: RawPoseFrame,
        gravityVector: Vec3,
        mirror: Bool = false
    ) -> FrameFeatures {
        var worldJoints: [String: Vec3] = [:]
        for (name, arr) in frame.joints {
            guard arr.count >= 3 else { continue }
            var p = applyGravityCorrection(point: Vec3(array: arr), gravityVector: gravityVector)
            if mirror {
                p = Vec3(-p.x, p.y, p.z)
            }
            worldJoints[name] = p
        }

        if mirror {
            let swapPairs = [
                ("leftHip", "rightHip"),
                ("leftKnee", "rightKnee"),
                ("leftAnkle", "rightAnkle"),
                ("leftShoulder", "rightShoulder"),
                ("leftHeel", "rightHeel"),
                ("leftFootIndex", "rightFootIndex")
            ]
            for (lName, rName) in swapPairs {
                if let lVal = worldJoints[lName], let rVal = worldJoints[rName] {
                    worldJoints[lName] = rVal
                    worldJoints[rName] = lVal
                }
            }
        }

        let z0 = Vec3(0, 0, 0)
        let root = worldJoints["root"] ?? z0
        let spine = worldJoints["spine"] ?? z0
        let centerShoulder = worldJoints["centerShoulder"] ?? z0
        let leftHip = worldJoints["leftHip"] ?? z0
        let leftKnee = worldJoints["leftKnee"] ?? z0
        let leftAnkle = worldJoints["leftAnkle"] ?? z0
        let rightHip = worldJoints["rightHip"] ?? z0
        let rightKnee = worldJoints["rightKnee"] ?? z0
        let rightAnkle = worldJoints["rightAnkle"] ?? z0

        let lThigh = leftKnee - leftHip
        let lShin = leftAnkle - leftKnee
        let rThigh = rightKnee - rightHip
        let rShin = rightAnkle - rightKnee

        let leftKneeFlex = angleBetweenDeg(lThigh, lShin)
        let rightKneeFlex = angleBetweenDeg(rThigh, rShin)

        let lowerSpine = spine - root
        let upperSpine = centerShoulder - spine
        let spineJackAngle = angleBetweenDeg(lowerSpine, upperSpine)

        let trunkVec = centerShoulder - root
        let trunkLeanDeg = angleBetweenDeg(trunkVec, Vec3(0.0, 1.0, 0.0))

        // Foot pitch angles: ONLY computed when real foot keypoints exist (never faked from ankles)
        let feetPresent = requiredFootJoints.allSatisfy { worldJoints[$0] != nil }
        let leftFootPitchDeg: Double
        let rightFootPitchDeg: Double
        let baseY: Double
        if feetPresent,
           let leftHeel = worldJoints["leftHeel"],
           let leftFootIndex = worldJoints["leftFootIndex"],
           let rightHeel = worldJoints["rightHeel"],
           let rightFootIndex = worldJoints["rightFootIndex"] {
            let lFootVec = (leftFootIndex - leftHeel).normalized
            let rFootVec = (rightFootIndex - rightHeel).normalized
            leftFootPitchDeg = asin(min(1.0, max(-1.0, lFootVec.y))) * 180.0 / .pi
            rightFootPitchDeg = asin(min(1.0, max(-1.0, rFootVec.y))) * 180.0 / .pi
            baseY = 0.5 * (leftHeel.y + rightHeel.y)
        } else {
            leftFootPitchDeg = 0.0
            rightFootPitchDeg = 0.0
            baseY = 0.5 * (leftAnkle.y + rightAnkle.y) - 0.05
        }

        let legScale = max(0.4, 0.5 * ((lThigh.norm + lShin.norm) + (rThigh.norm + rShin.norm)))
        let hipHeightNorm = (root.y - baseY) / legScale
        let shoulderHeightNorm = (centerShoulder.y - root.y) / legScale
        let hipXNorm = root.x / legScale

        return FrameFeatures(
            t: frame.t,
            left_knee_flex: leftKneeFlex,
            right_knee_flex: rightKneeFlex,
            mean_knee_flex: 0.5 * (leftKneeFlex + rightKneeFlex),
            spine_jack_angle: spineJackAngle,
            trunk_lean_deg: trunkLeanDeg,
            left_foot_pitch_deg: leftFootPitchDeg,
            right_foot_pitch_deg: rightFootPitchDeg,
            hip_height_norm: hipHeightNorm,
            shoulder_height_norm: shoulderHeightNorm,
            hip_x_norm: hipXNorm
        )
    }

    public static func parabolicPeakTime(
        t0: Double, y0: Double,
        t1: Double, y1: Double,
        t2: Double, y2: Double
    ) -> Double {
        let denom = 2.0 * (y0 - 2.0 * y1 + y2)
        guard abs(denom) >= 1e-9 else { return t1 }
        let dt = 0.5 * (t2 - t0)
        let offset = ((y0 - y2) / denom) * dt
        return t1 + min(dt, max(-dt, offset))
    }

    public static func detectTurnaroundTimes(
        features: [FrameFeatures],
        beatTimes: [Double],
        beatPeriodS: Double,
        searchWindowBeats: Double = 0.45
    ) -> [Double?] {
        let halfWin = searchWindowBeats * beatPeriodS
        var turnarounds: [Double?] = []

        for bTime in beatTimes {
            var indices: [Int] = []
            for (idx, f) in features.enumerated() {
                if f.t >= (bTime - halfWin) && f.t <= (bTime + halfWin) {
                    indices.append(idx)
                }
            }
            guard indices.count >= 3 else {
                turnarounds.append(nil)
                continue
            }

            let signal = indices.map { features[$0].mean_knee_flex - 40.0 * features[$0].hip_height_norm }
            guard let maxVal = signal.max(), let minVal = signal.min(), (maxVal - minVal) >= 3.0 else {
                turnarounds.append(nil)
                continue
            }

            var bestLocalIdx = 0
            for k in 1..<signal.count {
                if signal[k] > signal[bestLocalIdx] {
                    bestLocalIdx = k
                }
            }
            let globalIdx = indices[bestLocalIdx]
            if globalIdx > 0 && globalIdx < (features.count - 1) {
                let prev = features[globalIdx - 1]
                let curr = features[globalIdx]
                let next = features[globalIdx + 1]
                let yPrev = prev.mean_knee_flex - 40.0 * prev.hip_height_norm
                let yCurr = curr.mean_knee_flex - 40.0 * curr.hip_height_norm
                let yNext = next.mean_knee_flex - 40.0 * next.hip_height_norm
                let tPeak = parabolicPeakTime(
                    t0: prev.t, y0: yPrev,
                    t1: curr.t, y1: yCurr,
                    t2: next.t, y2: yNext
                )
                turnarounds.append(tPeak)
            } else {
                turnarounds.append(features[globalIdx].t)
            }
        }
        return turnarounds
    }

    private static func interpolateFeature(
        features: [FrameFeatures],
        tQuery: Double,
        key: String
    ) -> Double {
        guard let first = features.first, let last = features.last else { return 0.0 }
        if tQuery <= first.t { return first.value(forKey: key) }
        if tQuery >= last.t { return last.value(forKey: key) }
        for i in 0..<(features.count - 1) {
            let t0 = features[i].t
            let t1 = features[i + 1].t
            if t0 <= tQuery && tQuery <= t1 {
                let alpha = (tQuery - t0) / max(1e-9, t1 - t0)
                return (1.0 - alpha) * features[i].value(forKey: key) + alpha * features[i + 1].value(forKey: key)
            }
        }
        return last.value(forKey: key)
    }

    public static func scoreCoverage(frames: [RawPoseFrame], minConfidence: Double) -> Double {
        guard !frames.isEmpty else { return 0.0 }
        var validCount = 0
        for frame in frames {
            let confMap = frame.confidences ?? [:]
            let allValid = requiredJoints.allSatisfy { j in
                guard let coords = frame.joints[j], coords.count >= 3 else { return false }
                return (confMap[j] ?? 0.0) >= minConfidence
            }
            if allValid { validCount += 1 }
        }
        return Double(validCount) / Double(frames.count)
    }

    public static func scoreFootCoverage(frames: [RawPoseFrame], minConfidence: Double) -> Double {
        guard !frames.isEmpty else { return 0.0 }
        var validCount = 0
        for frame in frames {
            let confMap = frame.confidences ?? [:]
            let allValid = requiredFootJoints.allSatisfy { j in
                guard let coords = frame.joints[j], coords.count >= 3 else { return false }
                return (confMap[j] ?? 0.0) >= minConfidence
            }
            if allValid { validCount += 1 }
        }
        return Double(validCount) / Double(frames.count)
    }

    public static func verifyClapSync(
        wristDistances: [Double],
        frameHostTimes: [Double],
        audioOnsetHostTime: Double,
        maxToleranceMs: Double = 30.0
    ) -> ClapSyncResult {
        guard wristDistances.count >= 3, wristDistances.count == frameHostTimes.count else {
            return ClapSyncResult(synced: false, offset_ms: 999.0, visual_clap_host_time: nil)
        }
        var minIdx = 0
        for i in 1..<wristDistances.count {
            if wristDistances[i] < wristDistances[minIdx] {
                minIdx = i
            }
        }
        let tVis: Double
        if minIdx > 0 && minIdx < (wristDistances.count - 1) {
            tVis = parabolicPeakTime(
                t0: frameHostTimes[minIdx - 1], y0: -wristDistances[minIdx - 1],
                t1: frameHostTimes[minIdx], y1: -wristDistances[minIdx],
                t2: frameHostTimes[minIdx + 1], y2: -wristDistances[minIdx + 1]
            )
        } else {
            tVis = frameHostTimes[minIdx]
        }
        let offsetMs = roundTo((tVis - audioOnsetHostTime) * 1000.0, places: 2)
        return ClapSyncResult(
            synced: abs(offsetMs) <= maxToleranceMs,
            offset_ms: offsetMs,
            visual_clap_host_time: roundTo(tVis, places: 5)
        )
    }

    public static func scoreAttempt(
        attempt: PoseClip,
        reference: PoseClip,
        config: GrooveConfig
    ) -> AttemptScoreResult {
        let thresholds = config.scoring_thresholds
        let minConf = thresholds.coverage.min_joint_confidence
        let minValidRatio = thresholds.coverage.min_valid_frame_ratio
        let coverageRatio = scoreCoverage(
            frames: attempt.frames,
            minConfidence: minConf
        )
        let footCoverageRatio = scoreFootCoverage(
            frames: attempt.frames,
            minConfidence: minConf
        )
        let footScoringStatus = footCoverageRatio >= minValidRatio ? "available" : "unavailable"

        let userGravity = Vec3(array: attempt.gravity_vector ?? [0.0, -1.0, 0.0])
        let refGravity = Vec3(array: reference.gravity_vector ?? [0.0, -1.0, 0.0])
        let mirror = attempt.mirrored ?? false

        let userFeatures = attempt.frames.map { extractFrameFeatures(frame: $0, gravityVector: userGravity, mirror: mirror) }
        let refFeatures = reference.frames.map { extractFrameFeatures(frame: $0, gravityVector: refGravity, mirror: false) }

        let beatTimes = reference.beat_times
        let bpm = reference.bpm
        let beatPeriodS = 60.0 / bpm
        let audioLatencyMs = attempt.audio_latency_ms ?? 0.0

        // 1. Timing
        let refTurnarounds = detectTurnaroundTimes(
            features: refFeatures,
            beatTimes: beatTimes,
            beatPeriodS: beatPeriodS,
            searchWindowBeats: thresholds.timing.search_window_beats
        )
        let userTurnarounds = detectTurnaroundTimes(
            features: userFeatures,
            beatTimes: beatTimes,
            beatPeriodS: beatPeriodS,
            searchWindowBeats: thresholds.timing.search_window_beats
        )

        var perBeat: [BeatJudgment] = []
        var validOffsetsMs: [Double] = []
        var goodOrBetterCount = 0

        for (idx, bTime) in beatTimes.enumerated() {
            let countNum = idx + 1
            let tRef = refTurnarounds[idx] ?? bTime
            guard let tUsr = userTurnarounds[idx] else {
                perBeat.append(BeatJudgment(count_number: countNum, offset_ms: 999.0, judgment: "Miss"))
                continue
            }

            let offsetMs = ((tUsr - (audioLatencyMs / 1000.0)) - tRef) * 1000.0
            let absMs = abs(offsetMs)
            validOffsetsMs.append(offsetMs)

            let judgment: String
            if absMs <= thresholds.timing.perfect_max_ms {
                judgment = "Perfect"
                goodOrBetterCount += 1
            } else if absMs <= thresholds.timing.good_max_ms {
                judgment = "Good"
                goodOrBetterCount += 1
            } else if offsetMs < 0 {
                judgment = "Early"
            } else {
                judgment = "Late"
            }
            perBeat.append(BeatJudgment(count_number: countNum, offset_ms: roundTo(offsetMs, places: 2), judgment: judgment))
        }

        let meanOffsetMs = validOffsetsMs.isEmpty ? 999.0 : roundTo(validOffsetsMs.reduce(0, +) / Double(validOffsetsMs.count), places: 2)
        let goodOrBetterRatio = roundTo(Double(goodOrBetterCount) / Double(max(1, beatTimes.count)), places: 3)
        let worstBeat = perBeat.max(by: { abs($0.offset_ms) < abs($1.offset_ms) }) ?? BeatJudgment(count_number: 1, offset_ms: 0, judgment: "Perfect")

        // 2. Shape
        let footWeight = thresholds.shape.foot_pitch_weight
        let jointKeys: [(String, String, Double)] = [
            ("knees", "mean_knee_flex", 0.30),
            ("spine", "spine_jack_angle", 0.25),
            ("hips", "trunk_lean_deg", 0.15),
            ("left_foot", "left_foot_pitch_deg", 0.5 * footWeight),
            ("right_foot", "right_foot_pitch_deg", 0.5 * footWeight)
        ]

        var jointErrors: [String: [Double]] = [:]
        for (name, _, _) in jointKeys { jointErrors[name] = [] }
        var lateralErrors: [Double] = []

        for (idx, bTime) in beatTimes.enumerated() {
            let beatInfo = perBeat[idx]
            let offsetS = ((beatInfo.judgment != "Miss") ? (beatInfo.offset_ms / 1000.0) : 0.0) + (audioLatencyMs / 1000.0)
            for sampleDelta in [-0.12, 0.0, 0.12] {
                let tRef = bTime + sampleDelta
                let tUsr = tRef + offsetS
                for (jointName, featKey, _) in jointKeys {
                    let vRef = interpolateFeature(features: refFeatures, tQuery: tRef, key: featKey)
                    let vUsr = interpolateFeature(features: userFeatures, tQuery: tUsr, key: featKey)
                    jointErrors[jointName, default: []].append(abs(vUsr - vRef))
                }
                let xRef = interpolateFeature(features: refFeatures, tQuery: tRef, key: "hip_x_norm")
                let xUsr = interpolateFeature(features: userFeatures, tQuery: tUsr, key: "hip_x_norm")
                lateralErrors.append(abs(xUsr - xRef) * 90.0)
            }
        }

        var meanJointErr: [String: Double] = [:]
        for (name, vals) in jointErrors {
            meanJointErr[name] = vals.reduce(0, +) / Double(max(1, vals.count))
        }
        meanJointErr["hips", default: 0.0] += lateralErrors.reduce(0, +) / Double(max(1, lateralErrors.count))

        var weightedShape = 0.0
        for (jointName, _, weight) in jointKeys {
            let err = meanJointErr[jointName] ?? 0.0
            let comp = max(0.0, 100.0 * (1.0 - (err / thresholds.shape.max_angle_error_deg)))
            weightedShape += weight * comp
        }

        let worstJoints = meanJointErr
            .map { JointErrorSummary(joint: $0.key, mean_angle_error_deg: roundTo($0.value, places: 2)) }
            .sorted { $0.mean_angle_error_deg > $1.mean_angle_error_deg }

        let worstErr = worstJoints.first?.mean_angle_error_deg ?? 0.0
        if worstErr > thresholds.shape.max_single_joint_error_deg {
            let excessRatio = (worstErr - thresholds.shape.max_single_joint_error_deg) / max(1.0, thresholds.shape.max_angle_error_deg - thresholds.shape.max_single_joint_error_deg)
            let capScore = max(0.0, (thresholds.shape.pass_min_score - 2.0) * (1.0 - 0.6 * excessRatio))
            weightedShape = min(weightedShape, capScore)
        }
        let shapeScore = roundTo(weightedShape, places: 2)

        // 3. Groove
        let userKneeVals = userFeatures.map { $0.mean_knee_flex }
        let refKneeVals = refFeatures.map { $0.mean_knee_flex }
        let userKneeRange = (userKneeVals.max() ?? 0.0) - (userKneeVals.min() ?? 0.0)
        let refKneeRange = max(1.0, (refKneeVals.max() ?? 0.0) - (refKneeVals.min() ?? 0.0))
        let kneeFlexRatio = userKneeRange / refKneeRange
        let flexSubscore = (kneeFlexRatio < thresholds.groove.min_knee_flex_ratio)
            ? min(100.0, 100.0 * (kneeFlexRatio / max(0.01, thresholds.groove.min_knee_flex_ratio)))
            : 100.0

        let spineLagMs = estimateSpineKneeLagMs(features: userFeatures)
        let lagSubscore: Double
        if spineLagMs >= thresholds.groove.ideal_spine_lag_ms_min && spineLagMs <= thresholds.groove.ideal_spine_lag_ms_max {
            lagSubscore = 100.0
        } else if spineLagMs < thresholds.groove.ideal_spine_lag_ms_min {
            lagSubscore = max(0.0, 100.0 * (spineLagMs / max(1.0, thresholds.groove.ideal_spine_lag_ms_min)))
        } else {
            lagSubscore = max(0.0, 100.0 * (1.0 - (spineLagMs - thresholds.groove.ideal_spine_lag_ms_max) / 100.0))
        }

        let userDsj = computeDimensionlessJerk(features: userFeatures)
        let refDsj = max(1.0, computeDimensionlessJerk(features: refFeatures))
        let jerkRatio = userDsj / refDsj
        let smoothSubscore: Double
        if jerkRatio <= 1.15 {
            smoothSubscore = 100.0
        } else {
            smoothSubscore = max(0.0, 100.0 * (1.0 - (jerkRatio - 1.15) / max(0.1, thresholds.groove.max_jerk_ratio - 1.15)))
        }

        let grooveScore = roundTo(0.45 * flexSubscore + 0.30 * lagSubscore + 0.25 * smoothSubscore, places: 2)

        let coverageOk = coverageRatio >= minValidRatio
        let timingOk = goodOrBetterRatio >= thresholds.gate.min_good_or_better_beat_ratio
        let shapeOk = shapeScore >= thresholds.shape.pass_min_score
        let grooveOk = grooveScore >= thresholds.groove.pass_min_score
        let passed = coverageOk && timingOk && shapeOk && grooveOk

        return AttemptScoreResult(
            clip_id: attempt.clip_id,
            passed: passed,
            coverage_ratio: roundTo(coverageRatio, places: 3),
            foot_scoring_status: footScoringStatus,
            mean_offset_ms: meanOffsetMs,
            good_or_better_ratio: goodOrBetterRatio,
            shape_score: shapeScore,
            groove_score: grooveScore,
            knee_flex_ratio: roundTo(kneeFlexRatio, places: 3),
            spine_lag_ms: spineLagMs,
            worst_beat: worstBeat,
            worst_joints: Array(worstJoints.prefix(3))
        )
    }

    public static func measureClipLegScale(clip: PoseClip) -> Double {
        let grav = Vec3(array: clip.gravity_vector ?? [0.0, -1.0, 0.0])
        var scales: [Double] = []
        for frame in clip.frames {
            let j = frame.joints
            guard let lhArr = j["leftHip"], let lkArr = j["leftKnee"], let laArr = j["leftAnkle"],
                  let rhArr = j["rightHip"], let rkArr = j["rightKnee"], let raArr = j["rightAnkle"] else {
                continue
            }
            let lh = applyGravityCorrection(point: Vec3(array: lhArr), gravityVector: grav)
            let lk = applyGravityCorrection(point: Vec3(array: lkArr), gravityVector: grav)
            let la = applyGravityCorrection(point: Vec3(array: laArr), gravityVector: grav)
            let rh = applyGravityCorrection(point: Vec3(array: rhArr), gravityVector: grav)
            let rk = applyGravityCorrection(point: Vec3(array: rkArr), gravityVector: grav)
            let ra = applyGravityCorrection(point: Vec3(array: raArr), gravityVector: grav)
            let s = 0.5 * (((lk - lh).norm + (la - lk).norm) + ((rk - rh).norm + (ra - rk).norm))
            scales.append(s)
        }
        guard !scales.isEmpty else { return 0.82 }
        return roundTo(scales.reduce(0, +) / Double(scales.count), places: 4)
    }

    public static func calibrateUserBaseline(
        clips: [PoseClip],
        references: [String: PoseClip],
        config: GrooveConfig
    ) -> CalibrationReport {
        var cleanLegScales: [Double] = []
        var cleanTimingOffsets: [Double] = []
        var cleanKneeFlexRatios: [Double] = []
        var cleanSpineLags: [Double] = []
        var cleanGrooveScores: [Double] = []

        var positiveTotal = 0
        var positivePassed = 0
        var negativeTotal = 0
        var negativeRejected = 0
        var perClipResults: [CalibrationClipResult] = []

        for clip in clips {
            guard let ref = references[clip.move_tag] else { continue }
            let res = scoreAttempt(attempt: clip, reference: ref, config: config)
            let expectedPass = clip.expected?.passed ?? true
            let actualPass = res.passed

            if expectedPass {
                positiveTotal += 1
                if actualPass { positivePassed += 1 }
                if abs(res.mean_offset_ms) <= 30.0 {
                    cleanLegScales.append(measureClipLegScale(clip: clip))
                    cleanTimingOffsets.append(res.mean_offset_ms)
                    cleanKneeFlexRatios.append(res.knee_flex_ratio)
                    cleanSpineLags.append(res.spine_lag_ms)
                    cleanGrooveScores.append(res.groove_score)
                }
            } else {
                negativeTotal += 1
                if !actualPass { negativeRejected += 1 }
            }

            perClipResults.append(
                CalibrationClipResult(
                    clip_id: res.clip_id,
                    expected_pass: expectedPass,
                    actual_pass: actualPass,
                    matched: expectedPass == actualPass,
                    mean_offset_ms: res.mean_offset_ms,
                    shape_score: res.shape_score,
                    groove_score: res.groove_score,
                    coverage_ratio: res.coverage_ratio
                )
            )
        }

        let matchedClips = positivePassed + negativeRejected
        let totalClips = max(1, clips.count)
        let separationAccuracy = roundTo(Double(matchedClips) / Double(totalClips), places: 4)
        let cleanPassRate = roundTo(Double(positivePassed) / Double(max(1, positiveTotal)), places: 4)
        let negativeRejectionRate = roundTo(Double(negativeRejected) / Double(max(1, negativeTotal)), places: 4)

        let baselineGroove = cleanGrooveScores.isEmpty
            ? 75.0
            : roundTo(cleanGrooveScores.reduce(0, +) / Double(cleanGrooveScores.count), places: 2)
        let recommendedGrooveGate = roundTo(max(60.0, min(75.0, 0.65 * baselineGroove)), places: 1)

        let baseline = LearnerBaseline(
            personal_leg_scale_m: roundTo(cleanLegScales.reduce(0, +) / Double(max(1, cleanLegScales.count)), places: 4),
            baseline_timing_bias_ms: roundTo(cleanTimingOffsets.reduce(0, +) / Double(max(1, cleanTimingOffsets.count)), places: 2),
            baseline_knee_flex_ratio: roundTo(cleanKneeFlexRatios.reduce(0, +) / Double(max(1, cleanKneeFlexRatios.count)), places: 3),
            baseline_spine_lag_ms: roundTo(cleanSpineLags.reduce(0, +) / Double(max(1, cleanSpineLags.count)), places: 2),
            baseline_groove_score: baselineGroove,
            recommended_groove_gate: recommendedGrooveGate
        )

        return CalibrationReport(
            calibration_valid: separationAccuracy == 1.0 && clips.count >= 4,
            total_clips: clips.count,
            matched_clips: matchedClips,
            separation_accuracy: separationAccuracy,
            clean_pass_rate: cleanPassRate,
            negative_rejection_rate: negativeRejectionRate,
            learner_baseline: baseline,
            clip_results: perClipResults
        )
    }

    private static func estimateSpineKneeLagMs(features: [FrameFeatures]) -> Double {
        guard features.count >= 10 else { return 0.0 }
        let dt = features[1].t - features[0].t
        guard dt > 0 else { return 0.0 }

        let kneeSig = features.map { $0.mean_knee_flex }
        let spineSig = features.map { $0.spine_jack_angle }
        let kMean = kneeSig.reduce(0, +) / Double(kneeSig.count)
        let sMean = spineSig.reduce(0, +) / Double(spineSig.count)
        let kneeCentered = kneeSig.map { $0 - kMean }
        let spineCentered = spineSig.map { $0 - sMean }

        guard let kMax = kneeCentered.max(), let kMin = kneeCentered.min(), (kMax - kMin) >= 2.0,
              let sMax = spineCentered.max(), let sMin = spineCentered.min(), (sMax - sMin) >= 1.5 else {
            return 0.0
        }

        let maxShift = min(6, features.count / 4)
        var bestShift = 0
        var bestCorr = -1e18
        for shift in 0...maxShift {
            var corr = 0.0
            for i in 0..<(features.count - shift) {
                corr += kneeCentered[i] * spineCentered[i + shift]
            }
            if corr > bestCorr {
                bestCorr = corr
                bestShift = shift
            }
        }
        return roundTo(Double(bestShift) * dt * 1000.0, places: 2)
    }

    private static func computeDimensionlessJerk(features: [FrameFeatures]) -> Double {
        guard features.count >= 5 else { return 0.0 }
        let dt = features[1].t - features[0].t
        let y = features.map { $0.hip_height_norm }
        guard let yMax = y.max(), let yMin = y.min() else { return 1e9 }
        let amp = yMax - yMin
        if amp < 0.015 || dt <= 0 { return 1e9 }

        var jerkSqSum = 0.0
        let dt3 = dt * dt * dt
        for i in 1..<(y.count - 2) {
            let j = (y[i + 2] - 3.0 * y[i + 1] + 3.0 * y[i] - y[i - 1]) / dt3
            jerkSqSum += (j * j) * dt
        }
        let duration = min(1.0, (features.last?.t ?? 0.0) - (features.first?.t ?? 0.0))
        let dsj = (jerkSqSum * pow(duration, 5.0)) / (amp * amp)
        return roundTo(dsj / 1000.0, places: 2)
    }
}
