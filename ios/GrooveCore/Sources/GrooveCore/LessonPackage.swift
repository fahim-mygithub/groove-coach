import Foundation

/// Lesson package contract (spec §2.2, §8): load, validate, slice, stretch, and the adaptive-speed policy.
///
/// Port of `groove_eval/lesson_package.py`. Structure rules mirror `schemas/lesson_package.schema.json` (hand-built
/// in `ManifestSchema` below, so the app needs no schema file at runtime); cross-field rules, config merge, slicing,
/// stretching and `nextRate` follow the Python reference line for line.
///
/// Time bases:
/// - manifest times and reference frame times are media seconds on the original video timeline;
/// - `sliceReference` rebases a segment so t = 0 at `segment.start_s` (pad frames before it have t < 0);
/// - `stretch` maps that slice to wall-clock time at playback rate r: t / r, beat_times / r, bpm * r,
///   speed_pct = round(100 r).
public enum LessonPackage {

    public static let manifestSchema = "groove.lesson/1"
    public static let boundaryToleranceS = 0.040
    public static let rateEps = 1e-9
    public static let hardMinRate = 0.5
    public static let hardMaxRate = 1.0

    public enum Failure: Swift.Error, Equatable {
        case invalid([String])
        case unknownSegment(String)
        case rateOutOfRange(rate: Double, min: Double, max: Double)
    }

    // MARK: - JSON value

    /// Untyped JSON, used for `config_overrides` and the bundled config so merges keep every key.
    public enum JSONValue: Sendable, Equatable, Codable {
        case null
        case bool(Bool)
        case number(Double)
        case string(String)
        case array([JSONValue])
        case object([String: JSONValue])

        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let v = try? c.decode(Bool.self) { self = .bool(v) }
            else if let v = try? c.decode(Double.self) { self = .number(v) }
            else if let v = try? c.decode(String.self) { self = .string(v) }
            else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
            else { self = .object(try c.decode([String: JSONValue].self)) }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .null: try c.encodeNil()
            case .bool(let v): try c.encode(v)
            case .number(let v): try c.encode(v)
            case .string(let v): try c.encode(v)
            case .array(let v): try c.encode(v)
            case .object(let v): try c.encode(v)
            }
        }

        public static func parse(_ data: Data) throws -> JSONValue {
            try JSONDecoder().decode(JSONValue.self, from: data)
        }

        public var objectValue: [String: JSONValue]? {
            if case .object(let o) = self { return o }
            return nil
        }

        /// Decode this value into any Decodable (e.g. `GrooveScoringEngine.GrooveConfig` from a merged config).
        public func decoded<T: Decodable>(as type: T.Type) throws -> T {
            try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
        }

        fileprivate var typeName: String {
            switch self {
            case .null: return "null"
            case .bool: return "boolean"
            case .number: return "number"
            case .string: return "string"
            case .array: return "array"
            case .object: return "object"
            }
        }
    }

    // MARK: - Manifest model

    public struct AdaptiveSpeed: Sendable, Equatable, Codable {
        public var minRate: Double
        public var startRate: Double
        public var maxRate: Double
        public var stepUp: Double
        public var stepDown: Double
        public var promoteAfter: Int
        public var demoteAfter: Int
        public var unlockNextAtRate: Double

        enum CodingKeys: String, CodingKey {
            case minRate = "min_rate", startRate = "start_rate", maxRate = "max_rate"
            case stepUp = "step_up", stepDown = "step_down"
            case promoteAfter = "promote_after", demoteAfter = "demote_after"
            case unlockNextAtRate = "unlock_next_at_rate"
        }

        public init(
            minRate: Double, startRate: Double, maxRate: Double, stepUp: Double, stepDown: Double,
            promoteAfter: Int, demoteAfter: Int, unlockNextAtRate: Double
        ) {
            self.minRate = minRate
            self.startRate = startRate
            self.maxRate = maxRate
            self.stepUp = stepUp
            self.stepDown = stepDown
            self.promoteAfter = promoteAfter
            self.demoteAfter = demoteAfter
            self.unlockNextAtRate = unlockNextAtRate
        }

        /// Defaults justified in spec §8 Q6.
        public static let `default` = AdaptiveSpeed(
            minRate: 0.6, startRate: 0.7, maxRate: 1.0, stepUp: 0.1, stepDown: 0.05,
            promoteAfter: 2, demoteAfter: 2, unlockNextAtRate: 0.8
        )
    }

    public struct Segment: Sendable, Equatable, Codable {
        public var id: String
        public var kind: String?
        public var title: String
        public var startS: Double
        public var endS: Double
        public var teachOrder: Int
        public var difficulty: Int?
        public var focus: [String]?
        public var cues: [String]?
        public var configOverrides: JSONValue?
        public var adaptiveSpeed: AdaptiveSpeed?

        enum CodingKeys: String, CodingKey {
            case id, kind, title, difficulty, focus, cues
            case startS = "start_s", endS = "end_s", teachOrder = "teach_order"
            case configOverrides = "config_overrides", adaptiveSpeed = "adaptive_speed"
        }
    }

    public struct Window: Sendable, Equatable, Codable {
        public var kind: String
        public var startS: Double
        public var endS: Double
        public var mask: [String]?
        public var toleranceScale: [String: Double]?

        enum CodingKeys: String, CodingKey {
            case kind, mask
            case startS = "start_s", endS = "end_s", toleranceScale = "tolerance_scale"
        }
    }

    public struct Beat: Sendable, Equatable, Codable {
        public var t: Double
        public var phrase: Int
        public var count: Int
    }

    public struct BeatGrid: Sendable, Equatable, Codable {
        public var bpm: Double
        public var anchorS: Double
        public var source: String
        public var detector: String?
        public var beats: [Beat]

        enum CodingKeys: String, CodingKey {
            case bpm, source, detector, beats
            case anchorS = "anchor_s"
        }
    }

    public struct Requires: Sendable, Equatable, Codable {
        public var engineMajor: Int
        public var skeleton: String

        enum CodingKeys: String, CodingKey {
            case engineMajor = "engine_major", skeleton
        }
    }

    public struct Extractor: Sendable, Equatable, Codable {
        public var poseModel: String
        public var poseModelSha256: String
        public var handModel: String?
        public var handModelSha256: String?
        public var mediapipePython: String
        public var runningMode: String
        public var numPoses: Int

        enum CodingKeys: String, CodingKey {
            case poseModel = "pose_model", poseModelSha256 = "pose_model_sha256"
            case handModel = "hand_model", handModelSha256 = "hand_model_sha256"
            case mediapipePython = "mediapipe_python", runningMode = "running_mode", numPoses = "num_poses"
        }
    }

    public struct Video: Sendable, Equatable, Codable {
        public var file: String
        public var durationS: Double
        public var fps: Double
        public var width: Int
        public var height: Int
        public var mirrored: Bool
        public var defaultDisplayFlip: Bool

        enum CodingKeys: String, CodingKey {
            case file, fps, width, height, mirrored
            case durationS = "duration_s", defaultDisplayFlip = "default_display_flip"
        }
    }

    public struct Reference: Sendable, Equatable, Codable {
        public var file: String
        public var frameCount: Int

        enum CodingKeys: String, CodingKey {
            case file
            case frameCount = "frame_count"
        }
    }

    public struct Practice: Sendable, Equatable, Codable {
        public var countInBeats: Int
        public var adaptiveSpeed: AdaptiveSpeed

        enum CodingKeys: String, CodingKey {
            case countInBeats = "count_in_beats", adaptiveSpeed = "adaptive_speed"
        }
    }

    public struct Manifest: Sendable, Equatable, Codable {
        public var schema: String
        public var lessonID: String
        public var courseSlug: String
        public var lessonSlug: String
        public var packageVersion: Int
        public var title: String
        public var requires: Requires
        public var extractor: Extractor
        public var video: Video
        public var poster: String?
        public var reference: Reference
        public var beatGrid: BeatGrid
        public var segments: [Segment]
        public var windows: [Window]
        public var configOverrides: JSONValue
        public var practice: Practice
        public var files: [String: String]

        enum CodingKeys: String, CodingKey {
            case schema, title, requires, extractor, video, poster, reference, segments, windows, practice, files
            case lessonID = "lesson_id", courseSlug = "course_slug", lessonSlug = "lesson_slug"
            case packageVersion = "package_version", beatGrid = "beat_grid", configOverrides = "config_overrides"
        }
    }

    // MARK: - Structure schema (mirror of schemas/lesson_package.schema.json)

    indirect enum Rule: Sendable {
        case string(minLength: Int = 0, pattern: String? = nil)
        case oneOf([String])
        case constString(String)
        case constNumber(Double)
        case integer(min: Double? = nil, max: Double? = nil)
        case number(min: Double? = nil, max: Double? = nil, exclusiveMin: Double? = nil)
        case boolean
        case array(of: Rule, minItems: Int = 0)
        case object(
            required: [String] = [], properties: [String: Rule] = [:], additional: Additional = .any,
            propertyNames: Rule? = nil, minProperties: Int = 0
        )
        case anyObject

        enum Additional: Sendable {
            case forbidden
            case any
            case rule(Rule)
        }
    }

    enum ManifestSchema {
        static let slug = Rule.string(pattern: "^[a-z0-9]+(-[a-z0-9]+)*$")
        static let sha256 = Rule.string(pattern: "^[0-9a-f]{64}$")
        static let fileName = Rule.string(pattern: "^[A-Za-z0-9_.-]+$")
        static let jointName = Rule.oneOf(CanonicalSkeleton.canonicalJoints)
        static let rate = Rule.number(min: 0.5, max: 1.0)

        static let adaptiveSpeed = Rule.object(
            required: ["min_rate", "start_rate", "max_rate", "step_up", "step_down", "promote_after",
                       "demote_after", "unlock_next_at_rate"],
            properties: [
                "min_rate": rate, "start_rate": rate, "max_rate": rate,
                "step_up": .number(min: 0.01, max: 0.5), "step_down": .number(min: 0.01, max: 0.5),
                "promote_after": .integer(min: 1), "demote_after": .integer(min: 1),
                "unlock_next_at_rate": rate
            ],
            additional: .forbidden
        )

        static let manifest = Rule.object(
            required: ["schema", "lesson_id", "course_slug", "lesson_slug", "package_version", "title", "requires",
                       "extractor", "video", "reference", "beat_grid", "segments", "windows", "config_overrides",
                       "practice", "files"],
            properties: [
                "schema": .constString(LessonPackage.manifestSchema),
                "lesson_id": .string(pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"),
                "course_slug": slug,
                "lesson_slug": slug,
                "package_version": .integer(min: 1),
                "title": .string(minLength: 1),
                "requires": .object(
                    required: ["engine_major", "skeleton"],
                    properties: ["engine_major": .integer(min: 1), "skeleton": .constString(CanonicalSkeleton.skeletonID)],
                    additional: .forbidden
                ),
                "extractor": .object(
                    required: ["pose_model", "pose_model_sha256", "mediapipe_python", "running_mode", "num_poses"],
                    properties: [
                        "pose_model": .string(minLength: 1), "pose_model_sha256": sha256,
                        "hand_model": .string(minLength: 1), "hand_model_sha256": sha256,
                        "mediapipe_python": .string(pattern: "^[0-9]+\\.[0-9]+\\.[0-9]+$"),
                        "running_mode": .constString("VIDEO"), "num_poses": .constNumber(1)
                    ],
                    additional: .forbidden
                ),
                "video": .object(
                    required: ["file", "duration_s", "fps", "width", "height", "mirrored", "default_display_flip"],
                    properties: [
                        "file": fileName, "duration_s": .number(exclusiveMin: 0), "fps": .number(exclusiveMin: 0),
                        "width": .integer(min: 1), "height": .integer(min: 1),
                        "mirrored": .boolean, "default_display_flip": .boolean
                    ],
                    additional: .forbidden
                ),
                "poster": fileName,
                "reference": .object(
                    required: ["file", "frame_count"],
                    properties: ["file": fileName, "frame_count": .integer(min: 1)],
                    additional: .forbidden
                ),
                "beat_grid": .object(
                    required: ["bpm", "anchor_s", "source", "beats"],
                    properties: [
                        "bpm": .number(exclusiveMin: 0), "anchor_s": .number(min: 0),
                        "source": .oneOf(["author_confirmed", "detector"]),
                        "detector": .string(minLength: 1),
                        "beats": .array(
                            of: .object(
                                required: ["t", "phrase", "count"],
                                properties: ["t": .number(min: 0), "phrase": .integer(min: 1), "count": .integer(min: 1, max: 8)],
                                additional: .forbidden
                            ),
                            minItems: 1
                        )
                    ],
                    additional: .forbidden
                ),
                "segments": .array(
                    of: .object(
                        required: ["id", "title", "start_s", "end_s", "teach_order"],
                        properties: [
                            "id": .string(pattern: "^[A-Za-z0-9_-]+$"),
                            "kind": .oneOf(["segment", "full_run"]),
                            "title": .string(minLength: 1),
                            "start_s": .number(min: 0), "end_s": .number(exclusiveMin: 0),
                            "teach_order": .integer(min: 1),
                            "difficulty": .integer(min: 1, max: 5),
                            "focus": .array(of: .oneOf(["arms", "hands", "hips", "feet", "torso", "head"])),
                            "cues": .array(of: .string(minLength: 1)),
                            "config_overrides": .anyObject,
                            "adaptive_speed": adaptiveSpeed
                        ],
                        additional: .forbidden
                    ),
                    minItems: 1
                ),
                "windows": .array(
                    of: .object(
                        required: ["kind", "start_s", "end_s"],
                        properties: [
                            "kind": .oneOf(["clasp", "occlusion"]),
                            "start_s": .number(min: 0), "end_s": .number(exclusiveMin: 0),
                            "mask": .array(of: .oneOf(["hand_shape"])),
                            "tolerance_scale": .object(
                                additional: .rule(.number(exclusiveMin: 0)), propertyNames: jointName
                            )
                        ],
                        additional: .forbidden
                    )
                ),
                "config_overrides": .anyObject,
                "practice": .object(
                    required: ["count_in_beats", "adaptive_speed"],
                    properties: ["count_in_beats": .integer(min: 0, max: 16), "adaptive_speed": adaptiveSpeed],
                    additional: .forbidden
                ),
                "files": .object(additional: .rule(sha256), propertyNames: fileName, minProperties: 1)
            ],
            additional: .forbidden
        )
    }

    /// Errors (`path: message`) for `value` against a `Rule`; empty when valid.
    static func validate(_ value: JSONValue, against rule: Rule, path: String = "$") -> [String] {
        func isInteger(_ d: Double) -> Bool { d == d.rounded() }
        func matches(_ s: String, _ pattern: String) -> Bool {
            s.range(of: pattern, options: .regularExpression) != nil
        }
        switch rule {
        case .string(let minLength, let pattern):
            guard case .string(let s) = value else { return ["\(path): expected string, got \(value.typeName)"] }
            var errors: [String] = []
            if s.count < minLength { errors.append("\(path): shorter than \(minLength)") }
            if let pattern, !matches(s, pattern) { errors.append("\(path): '\(s)' does not match \(pattern)") }
            return errors
        case .oneOf(let allowed):
            if case .string(let s) = value, allowed.contains(s) { return [] }
            return ["\(path): \(value) not in \(allowed)"]
        case .constString(let expected):
            if case .string(let s) = value, s == expected { return [] }
            return ["\(path): expected '\(expected)'"]
        case .constNumber(let expected):
            if case .number(let d) = value, d == expected { return [] }
            return ["\(path): expected \(expected)"]
        case .boolean:
            if case .bool = value { return [] }
            return ["\(path): expected boolean, got \(value.typeName)"]
        case .integer(let lo, let hi):
            guard case .number(let d) = value, isInteger(d) else {
                return ["\(path): expected integer, got \(value.typeName)"]
            }
            var errors: [String] = []
            if let lo, d < lo { errors.append("\(path): \(d) < minimum \(lo)") }
            if let hi, d > hi { errors.append("\(path): \(d) > maximum \(hi)") }
            return errors
        case .number(let lo, let hi, let exLo):
            guard case .number(let d) = value else { return ["\(path): expected number, got \(value.typeName)"] }
            var errors: [String] = []
            if let lo, d < lo { errors.append("\(path): \(d) < minimum \(lo)") }
            if let hi, d > hi { errors.append("\(path): \(d) > maximum \(hi)") }
            if let exLo, d <= exLo { errors.append("\(path): \(d) <= exclusiveMinimum \(exLo)") }
            return errors
        case .array(let item, let minItems):
            guard case .array(let items) = value else { return ["\(path): expected array, got \(value.typeName)"] }
            var errors: [String] = []
            if items.count < minItems { errors.append("\(path): fewer than \(minItems) items") }
            for (i, v) in items.enumerated() { errors += validate(v, against: item, path: "\(path)[\(i)]") }
            return errors
        case .anyObject:
            if case .object = value { return [] }
            return ["\(path): expected object, got \(value.typeName)"]
        case .object(let required, let properties, let additional, let propertyNames, let minProperties):
            guard case .object(let obj) = value else { return ["\(path): expected object, got \(value.typeName)"] }
            var errors: [String] = []
            for key in required where obj[key] == nil { errors.append("\(path): missing required field '\(key)'") }
            if obj.count < minProperties { errors.append("\(path): fewer than \(minProperties) properties") }
            for key in obj.keys.sorted() {
                let sub = "\(path).\(key)"
                if let names = propertyNames {
                    errors += validate(.string(key), against: names, path: sub).map { "\($0) (property name)" }
                }
                if let rule = properties[key] {
                    errors += validate(obj[key]!, against: rule, path: sub)
                } else {
                    switch additional {
                    case .forbidden: errors.append("\(sub): unexpected field")
                    case .any: break
                    case .rule(let r): errors += validate(obj[key]!, against: r, path: sub)
                    }
                }
            }
            return errors
        }
    }

    // MARK: - Manifest validation

    /// The §3.2 config keys that do not exist in config/groove_config.json yet.
    static let newConfigKeys: [[String]: Rule] = [
        ["scoring_thresholds", "shape", "arm_weight"]: .number(min: 0.0, max: 1.0),
        ["scoring_thresholds", "gate", "timing_source"]: .oneOf(["bounce", "hits"])
    ]

    static func checkOverrides(
        _ override: JSONValue, base: JSONValue, path: [String], where label: String, errors: inout [String]
    ) {
        guard case .object(let overrideObj) = override else {
            errors.append("\(label): config_overrides must be an object")
            return
        }
        for key in overrideObj.keys.sorted() {
            let value = overrideObj[key]!
            let sub = path + [key]
            let full = "\(label).\(sub.joined(separator: "."))"
            if let rule = newConfigKeys[sub] {
                errors += validate(value, against: rule, path: full)
                continue
            }
            guard case .object(let baseObj) = base, let target = baseObj[key] else {
                errors.append("\(full): not a key of config/groove_config.json or a §3.2 key")
                continue
            }
            switch (target, value) {
            case (.object, _):
                checkOverrides(value, base: target, path: sub, where: label, errors: &errors)
            case (.bool, .bool), (.number, .number), (.string, .string), (.array, .array), (.null, .null):
                break
            case (.number, _):
                if case .bool = value { errors.append("\(full): type differs from the bundled config") }
                else { errors.append("\(full): expected a number") }
            default:
                errors.append("\(full): type differs from the bundled config")
            }
        }
    }

    /// Range rules of an adaptive-speed policy beyond the structure schema (spec §8 Q6).
    public static func policyErrors(_ p: AdaptiveSpeed, where label: String = "adaptive_speed") -> [String] {
        var errors: [String] = []
        let doc: JSONValue
        do { doc = try JSONValue.parse(JSONEncoder().encode(p)) } catch { return ["\(label): not encodable"] }
        errors += validate(doc, against: ManifestSchema.adaptiveSpeed, path: label)
        if errors.isEmpty {
            if !(p.minRate <= p.startRate && p.startRate <= p.maxRate) {
                errors.append("\(label): need min_rate <= start_rate <= max_rate")
            }
            if !(p.minRate <= p.unlockNextAtRate && p.unlockNextAtRate <= p.maxRate) {
                errors.append("\(label): need min_rate <= unlock_next_at_rate <= max_rate")
            }
        }
        return errors
    }

    private static func nearBeat(_ t: Double, _ beats: [Double]) -> Bool {
        beats.contains { abs(t - $0) <= boundaryToleranceS + rateEps }
    }

    /// All contract errors for a manifest document: structure first, then the cross-field rules of spec §2.2 / §8.
    /// `config` is the bundled `config/groove_config.json`.
    public static func validateManifest(data: Data, config: JSONValue) -> [String] {
        let doc: JSONValue
        do { doc = try JSONValue.parse(data) } catch { return ["$: not valid JSON"] }
        let structural = validate(doc, against: ManifestSchema.manifest)
        if !structural.isEmpty { return structural }
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            return ["$: manifest does not decode"]
        }
        return validateManifest(manifest, config: config)
    }

    /// Cross-field rules for an already-decoded manifest (structure is assumed valid).
    public static func validateManifest(_ manifest: Manifest, config: JSONValue) -> [String] {
        var errors: [String] = []
        let duration = manifest.video.durationS
        let beats = manifest.beatGrid.beats.map { $0.t }
        if beats.count > 1 {
            for i in 1..<beats.count where beats[i] <= beats[i - 1] {
                errors.append("$.beat_grid.beats[\(i)].t: beats must be strictly increasing")
            }
        }
        if let last = beats.last, last > duration + rateEps {
            errors.append("$.beat_grid.beats: beat after video end")
        }

        var seen = Set<String>()
        for (i, seg) in manifest.segments.enumerated() {
            let label = "$.segments[\(i)]"
            if !seen.insert(seg.id).inserted { errors.append("\(label).id: duplicate segment id '\(seg.id)'") }
            if !(0.0 <= seg.startS && seg.startS < seg.endS && seg.endS <= duration + rateEps) {
                errors.append("\(label): need 0 <= start_s < end_s <= video.duration_s")
            }
            for (key, t) in [("start_s", seg.startS), ("end_s", seg.endS)] where !nearBeat(t, beats) {
                errors.append("\(label).\(key): \(t) is not within \(Int(boundaryToleranceS * 1000)) ms of a beat")
            }
            if let o = seg.configOverrides {
                checkOverrides(o, base: config, path: [], where: "\(label).config_overrides", errors: &errors)
            }
            if let p = seg.adaptiveSpeed { errors += policyRangeErrors(p, label: "\(label).adaptive_speed") }
        }
        let orders = manifest.segments.map { $0.teachOrder }.sorted()
        if orders != (0..<orders.count).map({ $0 + 1 }) {
            errors.append("$.segments: teach_order must be 1..\(orders.count) with no gaps or repeats, got \(orders)")
        }

        for (i, w) in manifest.windows.enumerated()
        where !(0.0 <= w.startS && w.startS < w.endS && w.endS <= duration + rateEps) {
            errors.append("$.windows[\(i)]: need 0 <= start_s < end_s <= video.duration_s")
        }

        checkOverrides(manifest.configOverrides, base: config, path: [], where: "$.config_overrides", errors: &errors)
        errors += policyRangeErrors(manifest.practice.adaptiveSpeed, label: "$.practice.adaptive_speed")

        var needed = [manifest.video.file, manifest.reference.file]
        if let poster = manifest.poster { needed.append(poster) }
        for name in needed where manifest.files[name] == nil {
            errors.append("$.files: missing sha256 for '\(name)'")
        }
        if manifest.files["manifest.json"] != nil {
            errors.append("$.files: manifest.json cannot list its own hash")
        }
        return errors
    }

    private static func policyRangeErrors(_ p: AdaptiveSpeed, label: String) -> [String] {
        var errors: [String] = []
        if !(p.minRate <= p.startRate && p.startRate <= p.maxRate) {
            errors.append("\(label): need min_rate <= start_rate <= max_rate")
        }
        if !(p.minRate <= p.unlockNextAtRate && p.unlockNextAtRate <= p.maxRate) {
            errors.append("\(label): need min_rate <= unlock_next_at_rate <= max_rate")
        }
        return errors
    }

    /// Decode and validate a manifest; throws `Failure.invalid` with every error.
    public static func loadManifest(data: Data, config: JSONValue) throws -> Manifest {
        let errors = validateManifest(data: data, config: config)
        if !errors.isEmpty { throw Failure.invalid(errors) }
        return try JSONDecoder().decode(Manifest.self, from: data)
    }

    // MARK: - Lookups and config merge

    public static func segment(_ manifest: Manifest, id: String) throws -> Segment {
        guard let seg = manifest.segments.first(where: { $0.id == id }) else { throw Failure.unknownSegment(id) }
        return seg
    }

    /// Segment ids in teach_order (A, B, C, D, full for IMG_4941).
    public static func teachingSequence(_ manifest: Manifest) -> [String] {
        manifest.segments.sorted { $0.teachOrder < $1.teachOrder }.map { $0.id }
    }

    /// The segment's own adaptive_speed policy, else the lesson's `practice.adaptive_speed`.
    public static func segmentPolicy(_ manifest: Manifest, id: String) throws -> AdaptiveSpeed {
        try segment(manifest, id: id).adaptiveSpeed ?? manifest.practice.adaptiveSpeed
    }

    /// Recursive merge; override wins on leaves and non-object values replace whole subtrees.
    public static func deepMerge(_ base: JSONValue, _ override: JSONValue) -> JSONValue {
        guard case .object(let b) = base, case .object(let o) = override else { return override }
        var out = b
        for (key, value) in o {
            if let existing = out[key] {
                out[key] = deepMerge(existing, value)
            } else {
                out[key] = value
            }
        }
        return .object(out)
    }

    /// Bundled config < lesson `config_overrides` < segment `config_overrides` (spec §3.2).
    public static func segmentConfig(config: JSONValue, manifest: Manifest, segmentID: String) throws -> JSONValue {
        let seg = try segment(manifest, id: segmentID)
        let merged = deepMerge(config, manifest.configOverrides)
        return deepMerge(merged, seg.configOverrides ?? .object([:]))
    }

    // MARK: - Slice and stretch

    /// A sliced (and possibly stretched) reference: the `PoseClip` fields plus the rebased windows.
    public struct Clip: Sendable {
        public var clipID: String
        public var moveTag: String
        public var bpm: Double
        public var beatTimes: [Double]
        public var gravityVector: [Double]
        public var mirrored: Bool
        public var audioLatencyMs: Double
        public var speedPct: Int
        public var segmentStartS: Double
        public var segmentEndS: Double
        public var windows: [Window]
        public var frames: [GrooveScoringEngine.RawPoseFrame]
        public var rate: Double?

        public var poseClip: GrooveScoringEngine.PoseClip {
            GrooveScoringEngine.PoseClip(
                clip_id: clipID, move_tag: moveTag, bpm: bpm, beat_times: beatTimes,
                gravity_vector: gravityVector, mirrored: mirrored, audio_latency_ms: audioLatencyMs,
                speed_pct: speedPct, frames: frames
            )
        }
    }

    private static func retimed(_ f: GrooveScoringEngine.RawPoseFrame, _ t: Double) -> GrooveScoringEngine.RawPoseFrame {
        GrooveScoringEngine.RawPoseFrame(t: t, joints: f.joints, confidences: f.confidences, hands: f.hands)
    }

    /// A segment of the lesson reference as a standalone clip, rebased so t = 0 at `segment.start_s`.
    ///
    /// Frames: media time in [start - pad, end + pad] with pad = padBeats * 60 / bpm. Beats: those in
    /// [start - 40 ms, end - 40 ms), so the beat that opens the next segment is not graded twice. Windows
    /// overlapping the segment are kept, rebased.
    public static func sliceReference(
        frames referenceFrames: [GrooveScoringEngine.RawPoseFrame],
        gravityVector: [Double]? = nil,
        manifest: Manifest,
        segmentID: String,
        padBeats: Double = 0.5
    ) throws -> Clip {
        let seg = try segment(manifest, id: segmentID)
        let start = seg.startS, end = seg.endS
        let bpm = manifest.beatGrid.bpm
        let pad = padBeats * 60.0 / bpm
        let frames = referenceFrames
            .filter { start - pad - rateEps <= $0.t && $0.t <= end + pad + rateEps }
            .map { retimed($0, $0.t - start) }
        let beatTimes = manifest.beatGrid.beats
            .filter { start - boundaryToleranceS <= $0.t && $0.t < end - boundaryToleranceS }
            .map { $0.t - start }
        let windows = manifest.windows
            .filter { $0.startS < end && $0.endS > start }
            .map { w -> Window in
                var out = w
                out.startS = w.startS - start
                out.endS = w.endS - start
                return out
            }
        return Clip(
            clipID: "\(manifest.lessonSlug)/\(segmentID)", moveTag: segmentID, bpm: bpm, beatTimes: beatTimes,
            gravityVector: gravityVector ?? [0.0, -1.0, 0.0], mirrored: false, audioLatencyMs: 0.0, speedPct: 100,
            segmentStartS: start, segmentEndS: end, windows: windows, frames: frames, rate: nil
        )
    }

    /// Round a playback rate to 0.01 (half up), so step arithmetic never drifts (0.7 + 0.1 -> 0.8 exactly).
    public static func quantizeRate(_ rate: Double) -> Double {
        (rate * 100.0 + 0.5).rounded(.down) / 100.0
    }

    @discardableResult
    public static func checkRate(_ rate: Double, policy: AdaptiveSpeed? = nil) throws -> Double {
        let lo = policy?.minRate ?? hardMinRate
        let hi = policy?.maxRate ?? hardMaxRate
        if !(lo - rateEps <= rate && rate <= hi + rateEps) {
            throw Failure.rateOutOfRange(rate: rate, min: lo, max: hi)
        }
        return rate
    }

    /// A sliced reference played at `rate`, in wall-clock time: t / rate, beat_times / rate, bpm * rate.
    /// Any rate in [policy.min_rate, policy.max_rate] is accepted ([0.5, 1.0] without a policy).
    public static func stretch(_ clip: Clip, rate: Double, policy: AdaptiveSpeed? = nil) throws -> Clip {
        let r = try checkRate(rate, policy: policy)
        var out = clip
        out.frames = clip.frames.map { retimed($0, $0.t / r) }
        out.beatTimes = clip.beatTimes.map { $0 / r }
        out.bpm = clip.bpm * r
        out.speedPct = Int((r * 100.0 + 0.5).rounded(.down))
        out.rate = r
        out.windows = clip.windows.map { w -> Window in
            var o = w
            o.startS = w.startS / r
            o.endS = w.endS / r
            return o
        }
        return out
    }

    // MARK: - Adaptive speed

    /// One finished take of a segment. `rate` defaults to the rate the policy offered.
    public struct Take: Sendable, Equatable {
        public var passed: Bool
        public var rate: Double?

        public init(passed: Bool, rate: Double? = nil) {
            self.passed = passed
            self.rate = rate
        }
    }

    /// Playback rate for the next take of a segment, and whether the next segment is unlocked.
    ///
    /// `history` is this segment's takes, oldest first. Replaying from `start_rate`:
    /// - a take at a different rate than the current one (the learner overrode it) moves the current rate there and
    ///   restarts both streaks;
    /// - `promote_after` consecutive passes step up by `step_up`, `demote_after` consecutive fails step down by
    ///   `step_down`; either step restarts the streaks; rates are clamped to [min_rate, max_rate] and quantized;
    /// - unlocked once any take passed at a rate >= `unlock_next_at_rate` (sticky).
    public static func nextRate(policy: AdaptiveSpeed, history: [Take]) throws -> (rate: Double, unlocked: Bool) {
        let errors = policyErrors(policy)
        if !errors.isEmpty { throw Failure.invalid(errors) }
        let lo = policy.minRate, hi = policy.maxRate
        func clamp(_ r: Double) -> Double { min(hi, max(lo, quantizeRate(r))) }

        var current = clamp(policy.startRate)
        var passes = 0, fails = 0
        var unlocked = false
        for take in history {
            if let r = take.rate {
                let takenAt = clamp(r)
                if abs(takenAt - current) > rateEps {
                    current = takenAt
                    passes = 0
                    fails = 0
                }
            }
            if take.passed {
                passes += 1
                fails = 0
                if current >= policy.unlockNextAtRate - rateEps { unlocked = true }
            } else {
                passes = 0
                fails += 1
            }
            if passes >= policy.promoteAfter {
                current = clamp(current + policy.stepUp)
                passes = 0
            } else if fails >= policy.demoteAfter {
                current = clamp(current - policy.stepDown)
                fails = 0
            }
        }
        return (current, unlocked)
    }
}
