import Foundation

/// Settle-after-move segmentation (dance "hit" detection).
/// Per-frame motion energy is the torso-scale-normalised speed (torso lengths per second) of the chosen joints,
/// averaged over a short trailing window. Hysteresis turns it into hit events: motion drops from moving
/// (energy >= movingThreshold) to settled (energy < settleThreshold for at least minSettleSeconds).
/// Foundation-only; mirrors `groove_eval/segmentation.py` with identical defaults.
public enum MoveSegmenter {

    public static let defaultJoints: [String] = [
        "leftWrist", "rightWrist", "leftAnkle", "rightAnkle",
        "leftHeel", "rightHeel", "leftFootIndex", "rightFootIndex"
    ]

    public struct Config: Sendable, Equatable {
        public var joints: [String]
        public var windowSeconds: Double
        public var movingThreshold: Double
        public var settleThreshold: Double
        public var minSettleSeconds: Double

        public init(
            joints: [String] = MoveSegmenter.defaultJoints,
            windowSeconds: Double = 0.110,
            movingThreshold: Double = 1.0,
            settleThreshold: Double = 0.4,
            minSettleSeconds: Double = 0.115
        ) {
            self.joints = joints
            self.windowSeconds = windowSeconds
            self.movingThreshold = movingThreshold
            self.settleThreshold = settleThreshold
            self.minSettleSeconds = minSettleSeconds
        }
    }

    public struct HitEvent: Sendable, Equatable {
        public let timestamp: Double
        public let peakSpeed: Double
        public let settleDuration: Double

        public init(timestamp: Double, peakSpeed: Double, settleDuration: Double) {
            self.timestamp = timestamp
            self.peakSpeed = peakSpeed
            self.settleDuration = settleDuration
        }
    }

    public struct BeatPair: Sendable, Equatable {
        public let hitTimestamp: Double
        public let beatTimestamp: Double
        /// (hit - beat) * 1000; positive means the hit landed late.
        public let offsetMs: Double

        public init(hitTimestamp: Double, beatTimestamp: Double, offsetMs: Double) {
            self.hitTimestamp = hitTimestamp
            self.beatTimestamp = beatTimestamp
            self.offsetMs = offsetMs
        }
    }

    private static func distance(_ a: [Double], _ b: [Double]) -> Double {
        var sum = 0.0
        for k in 0..<3 {
            let av = k < a.count ? a[k] : 0.0
            let bv = k < b.count ? b[k] : 0.0
            sum += (bv - av) * (bv - av)
        }
        return sum.squareRoot()
    }

    /// Mean root -> centerShoulder distance over frames having both joints; 1.0 when unavailable.
    public static func torsoScale(frames: [GrooveScoringEngine.RawPoseFrame]) -> Double {
        var total = 0.0
        var count = 0
        for frame in frames {
            guard let root = frame.joints["root"], let shoulder = frame.joints["centerShoulder"] else { continue }
            total += distance(root, shoulder)
            count += 1
        }
        if count == 0 { return 1.0 }
        let mean = total / Double(count)
        return mean > 0.0 ? mean : 1.0
    }

    /// Per-frame energy: mean over available joints of |p_i - p_j| / (t_i - t_j) / torsoScale, where j is the earliest
    /// earlier frame with t_j >= t_i - window (at least one frame back). Frame 0 has energy 0.
    public static func motionEnergy(
        frames: [GrooveScoringEngine.RawPoseFrame],
        config: Config = Config()
    ) -> [Double] {
        let scale = torsoScale(frames: frames)
        var energies = [Double](repeating: 0.0, count: frames.count)
        guard frames.count > 1 else { return energies }
        for i in 1..<frames.count {
            let tI = frames[i].t
            var j = i - 1
            while j > 0 && frames[j - 1].t >= tI - config.windowSeconds {
                j -= 1
            }
            let dt = tI - frames[j].t
            if dt <= 0.0 { continue }
            var total = 0.0
            var count = 0
            for name in config.joints {
                guard let a = frames[j].joints[name], let b = frames[i].joints[name] else { continue }
                total += distance(a, b) / dt / scale
                count += 1
            }
            if count > 0 { energies[i] = total / Double(count) }
        }
        return energies
    }

    /// Detect hit events. `timestamp` is the first settled frame; `settleDuration` is the settled time at the frame
    /// that confirmed the hit. Motion still in progress, or a settle shorter than minSettleSeconds at clip end,
    /// produces no hit.
    public static func detectHits(
        frames: [GrooveScoringEngine.RawPoseFrame],
        config: Config = Config()
    ) -> [HitEvent] {
        let energies = motionEnergy(frames: frames, config: config)
        var hits: [HitEvent] = []
        var moving = false
        var peak = 0.0
        var settleStart: Double? = nil
        for (frame, energy) in zip(frames, energies) {
            let t = frame.t
            if !moving {
                if energy >= config.movingThreshold {
                    moving = true
                    peak = energy
                    settleStart = nil
                }
                continue
            }
            if energy >= config.settleThreshold {
                peak = max(peak, energy)
                settleStart = nil
                continue
            }
            if settleStart == nil { settleStart = t }
            if let start = settleStart, t - start >= config.minSettleSeconds {
                hits.append(HitEvent(timestamp: start, peakSpeed: peak, settleDuration: t - start))
                moving = false
                peak = 0.0
                settleStart = nil
            }
        }
        return hits
    }

    /// Pair each hit with the nearest beat within `toleranceMs` (earlier beat wins ties). Matched hits only.
    public static func pairHitsToBeats(
        hits: [HitEvent],
        beats: [Double],
        toleranceMs: Double = 100.0
    ) -> [BeatPair] {
        var pairs: [BeatPair] = []
        for hit in hits {
            var best: Double? = nil
            var bestAbs = Double.infinity
            for beat in beats {
                let d = abs(hit.timestamp - beat)
                if d < bestAbs {
                    bestAbs = d
                    best = beat
                }
            }
            guard let beat = best else { continue }
            let offsetMs = (hit.timestamp - beat) * 1000.0
            if abs(offsetMs) <= toleranceMs {
                pairs.append(BeatPair(hitTimestamp: hit.timestamp, beatTimestamp: beat, offsetMs: offsetMs))
            }
        }
        return pairs
    }
}
