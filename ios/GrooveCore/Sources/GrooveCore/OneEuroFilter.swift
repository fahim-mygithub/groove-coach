import Foundation

/// One Euro adaptive smoothing filter (Casiez, Roussel, Vogel; CHI 2012).
/// Adaptive low-pass whose cutoff rises with signal speed: steady during holds, low lag on fast footwork.
/// Mirrors `groove_eval/one_euro.py` with identical defaults and math.
///
/// Conventions: the first sample passes through unchanged (derivative estimate starts at zero); a sample
/// whose timestamp is not strictly greater than the previous one is ignored and the last filtered value
/// is returned.
public enum OneEuro {
    public static let defaultMinCutoff = 1.2
    public static let defaultBeta = 3.0
    public static let defaultDCutoff = 1.0

    static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1.0 / (2.0 * Double.pi * cutoff)
        return 1.0 / (1.0 + tau / dt)
    }

    /// Scalar filter over timestamped samples.
    public struct Filter: Sendable {
        public var minCutoff: Double
        public var beta: Double
        public var dCutoff: Double
        private var lastT: Double?
        private var x = 0.0
        private var dx = 0.0

        public init(
            minCutoff: Double = OneEuro.defaultMinCutoff,
            beta: Double = OneEuro.defaultBeta,
            dCutoff: Double = OneEuro.defaultDCutoff
        ) {
            self.minCutoff = minCutoff
            self.beta = beta
            self.dCutoff = dCutoff
        }

        public mutating func reset() {
            lastT = nil
            x = 0.0
            dx = 0.0
        }

        public mutating func filter(_ value: Double, t: Double) -> Double {
            guard let prevT = lastT else {
                lastT = t
                x = value
                dx = 0.0
                return value
            }
            let dt = t - prevT
            guard dt > 0.0 else { return x }
            let rawDx = (value - x) / dt
            dx += OneEuro.alpha(cutoff: dCutoff, dt: dt) * (rawDx - dx)
            let cutoff = minCutoff + beta * abs(dx)
            x += OneEuro.alpha(cutoff: cutoff, dt: dt) * (value - x)
            lastT = t
            return x
        }
    }

    /// Three independent scalar filters over a `Vec3` sharing one timestamp.
    public struct Filter3D: Sendable {
        private var fx: Filter
        private var fy: Filter
        private var fz: Filter

        public init(
            minCutoff: Double = OneEuro.defaultMinCutoff,
            beta: Double = OneEuro.defaultBeta,
            dCutoff: Double = OneEuro.defaultDCutoff
        ) {
            let f = Filter(minCutoff: minCutoff, beta: beta, dCutoff: dCutoff)
            fx = f
            fy = f
            fz = f
        }

        public mutating func reset() {
            fx.reset()
            fy.reset()
            fz.reset()
        }

        public mutating func filter(_ p: GrooveScoringEngine.Vec3, t: Double) -> GrooveScoringEngine.Vec3 {
            GrooveScoringEngine.Vec3(
                fx.filter(p.x, t: t),
                fy.filter(p.y, t: t),
                fz.filter(p.z, t: t)
            )
        }
    }

    /// Dictionary of joint name -> 3D filter, fed with timestamped pose frames.
    public struct LandmarkBank: Sendable {
        private let minCutoff: Double
        private let beta: Double
        private let dCutoff: Double
        private var filters: [String: Filter3D] = [:]

        public init(
            minCutoff: Double = OneEuro.defaultMinCutoff,
            beta: Double = OneEuro.defaultBeta,
            dCutoff: Double = OneEuro.defaultDCutoff
        ) {
            self.minCutoff = minCutoff
            self.beta = beta
            self.dCutoff = dCutoff
        }

        public mutating func reset() {
            filters.removeAll()
        }

        public mutating func filter(joints: [String: [Double]], t: Double) -> [String: [Double]] {
            var out: [String: [Double]] = [:]
            for (name, arr) in joints {
                var f = filters[name] ?? Filter3D(minCutoff: minCutoff, beta: beta, dCutoff: dCutoff)
                let r = f.filter(GrooveScoringEngine.Vec3(array: arr), t: t)
                filters[name] = f
                out[name] = [r.x, r.y, r.z]
            }
            return out
        }

        public mutating func filter(_ frame: GrooveScoringEngine.RawPoseFrame) -> GrooveScoringEngine.RawPoseFrame {
            GrooveScoringEngine.RawPoseFrame(
                t: frame.t,
                joints: filter(joints: frame.joints, t: frame.t),
                confidences: frame.confidences,
                hands: frame.hands
            )
        }
    }
}
