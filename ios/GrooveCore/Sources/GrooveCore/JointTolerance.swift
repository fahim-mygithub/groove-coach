import Foundation

/// Per-joint tolerances derived from the spread of aligned golden performances,
/// plus per-frame verdicts and correction hints for a learner frame.
///
/// Coordinate convention for hint labels: +x = right, +y = up, +z = toward the viewer.
/// Positions use population standard deviation (single reference => std 0 => floor).
public enum JointTolerance {
    public typealias Vec3 = GrooveScoringEngine.Vec3

    public struct Config: Sendable {
        /// tolerance = clamp(k * stddev, floor, ceiling)
        public var k: Double
        public var positionFloor: Double
        public var positionCeiling: Double
        public var angleFloorDeg: Double
        public var angleCeilingDeg: Double
        /// error <= tol: ok; error <= warnFactor * tol: warn; otherwise off.
        public var warnFactor: Double

        public init(
            k: Double = 2.0,
            positionFloor: Double = 0.03,
            positionCeiling: Double = 0.25,
            angleFloorDeg: Double = 5.0,
            angleCeilingDeg: Double = 45.0,
            warnFactor: Double = 2.0
        ) {
            self.k = k
            self.positionFloor = positionFloor
            self.positionCeiling = positionCeiling
            self.angleFloorDeg = angleFloorDeg
            self.angleCeilingDeg = angleCeilingDeg
            self.warnFactor = warnFactor
        }
    }

    /// A joint angle measured at `joint` between the segments to `parent` and `child`.
    public struct AngleTriple: Sendable, Equatable {
        public let name: String
        public let parent: String
        public let joint: String
        public let child: String

        public init(name: String, parent: String, joint: String, child: String) {
            self.name = name
            self.parent = parent
            self.joint = joint
            self.child = child
        }
    }

    public static let defaultAngleTriples: [AngleTriple] = [
        AngleTriple(name: "leftKnee", parent: "leftHip", joint: "leftKnee", child: "leftAnkle"),
        AngleTriple(name: "rightKnee", parent: "rightHip", joint: "rightKnee", child: "rightAnkle"),
        AngleTriple(name: "leftElbow", parent: "leftShoulder", joint: "leftElbow", child: "leftWrist"),
        AngleTriple(name: "rightElbow", parent: "rightShoulder", joint: "rightElbow", child: "rightWrist")
    ]

    public enum Severity: String, Sendable, Codable {
        case ok, warn, off
    }

    public struct JointVerdict: Sendable, Equatable {
        public let joint: String
        public let error: Double
        public let tolerance: Double
        public let severity: Severity
        /// Unit vector from learner toward reference (zero when ok).
        public let direction: Vec3
        public let hint: String?
    }

    public struct AngleVerdict: Sendable, Equatable {
        public let name: String
        /// |learner - reference| in degrees.
        public let error: Double
        public let tolerance: Double
        public let severity: Severity
        public let hint: String?
    }

    /// Minimal frame view so callers can pass `RawPoseFrame.joints` directly.
    public struct RawFrame: Sendable {
        public let joints: [String: [Double]]
        public init(joints: [String: [Double]]) { self.joints = joints }
        public init(_ frame: GrooveScoringEngine.RawPoseFrame) { self.joints = frame.joints }
    }

    // MARK: - Tolerances

    /// Position tolerance per joint from aligned frames (one frame per golden performance).
    public static func positionTolerances(
        references: [RawFrame],
        config: Config = Config()
    ) -> [String: Double] {
        var out: [String: Double] = [:]
        let names = Set(references.flatMap { $0.joints.keys })
        for name in names {
            let pts = references.compactMap { point($0, name) }
            guard !pts.isEmpty else { continue }
            let n = Double(pts.count)
            let mx = pts.map { $0.x }.reduce(0, +) / n
            let my = pts.map { $0.y }.reduce(0, +) / n
            let mz = pts.map { $0.z }.reduce(0, +) / n
            let variance = pts.map {
                ($0.x - mx) * ($0.x - mx) + ($0.y - my) * ($0.y - my) + ($0.z - mz) * ($0.z - mz)
            }.reduce(0, +) / n
            out[name] = clamp(config.k * variance.squareRoot(), config.positionFloor, config.positionCeiling)
        }
        return out
    }

    /// Angle tolerance (degrees) per triple from aligned frames.
    public static func angleTolerances(
        references: [RawFrame],
        triples: [AngleTriple] = defaultAngleTriples,
        config: Config = Config()
    ) -> [String: Double] {
        var out: [String: Double] = [:]
        for t in triples {
            let angles = references.compactMap { angleDeg($0, t) }
            guard !angles.isEmpty else { continue }
            let n = Double(angles.count)
            let mean = angles.reduce(0, +) / n
            let variance = angles.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / n
            out[t.name] = clamp(config.k * variance.squareRoot(), config.angleFloorDeg, config.angleCeilingDeg)
        }
        return out
    }

    // MARK: - Verdicts

    /// Verdicts for every joint present in learner, reference and tolerances, sorted by joint name.
    public static func evaluate(
        learner: RawFrame,
        reference: RawFrame,
        tolerances: [String: Double],
        config: Config = Config()
    ) -> [JointVerdict] {
        var out: [JointVerdict] = []
        for name in tolerances.keys.sorted() {
            guard let l = point(learner, name), let r = point(reference, name), let tol = tolerances[name] else { continue }
            let delta = r - l
            let err = delta.norm
            let sev = severity(err, tol, config.warnFactor)
            if sev == .ok {
                out.append(JointVerdict(joint: name, error: err, tolerance: tol, severity: sev,
                                        direction: Vec3(0, 0, 0), hint: nil))
            } else {
                out.append(JointVerdict(joint: name, error: err, tolerance: tol, severity: sev,
                                        direction: delta.normalized, hint: hint(name, delta)))
            }
        }
        return out
    }

    public static func evaluateAngles(
        learner: RawFrame,
        reference: RawFrame,
        tolerances: [String: Double],
        triples: [AngleTriple] = defaultAngleTriples,
        config: Config = Config()
    ) -> [AngleVerdict] {
        var out: [AngleVerdict] = []
        for t in triples.sorted(by: { $0.name < $1.name }) {
            guard let tol = tolerances[t.name],
                  let l = angleDeg(learner, t), let r = angleDeg(reference, t) else { continue }
            let err = abs(l - r)
            let sev = severity(err, tol, config.warnFactor)
            var h: String? = nil
            if sev != .ok {
                h = (r > l ? "open " : "bend ") + words(t.name)
            }
            out.append(AngleVerdict(name: t.name, error: err, tolerance: tol, severity: sev, hint: h))
        }
        return out
    }

    // MARK: - Helpers

    static func point(_ f: RawFrame, _ name: String) -> Vec3? {
        guard let c = f.joints[name], c.count >= 3 else { return nil }
        return Vec3(c[0], c[1], c[2])
    }

    static func angleDeg(_ f: RawFrame, _ t: AngleTriple) -> Double? {
        guard let a = point(f, t.parent), let b = point(f, t.joint), let c = point(f, t.child) else { return nil }
        let u = a - b
        let v = c - b
        let nu = u.norm
        let nv = v.norm
        guard nu >= 1e-9, nv >= 1e-9 else { return nil }
        let cosine = max(-1.0, min(1.0, Vec3.dot(u, v) / (nu * nv)))
        return acos(cosine) * 180.0 / Double.pi
    }

    static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        max(lo, min(hi, x))
    }

    static func severity(_ err: Double, _ tol: Double, _ warnFactor: Double) -> Severity {
        if err <= tol { return .ok }
        if err <= warnFactor * tol { return .warn }
        return .off
    }

    /// "leftWrist" -> "left wrist".
    static func words(_ name: String) -> String {
        var s = ""
        for ch in name {
            if ch.isUppercase { s += " " + String(ch).lowercased() } else { s.append(ch) }
        }
        return s
    }

    /// Label for the dominant axis of the move needed (ties resolve y, then x, then z).
    static func hint(_ joint: String, _ d: Vec3) -> String {
        let ax = abs(d.x), ay = abs(d.y), az = abs(d.z)
        let w = words(joint)
        if ay >= ax && ay >= az { return (d.y > 0 ? "raise " : "lower ") + w }
        if ax >= az { return "move " + w + (d.x > 0 ? " right" : " left") }
        return "move " + w + (d.z > 0 ? " forward" : " back")
    }
}
