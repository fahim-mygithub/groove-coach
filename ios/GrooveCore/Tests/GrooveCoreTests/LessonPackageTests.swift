import XCTest
@testable import GrooveCore

final class LessonPackageTests: XCTestCase {
    typealias LP = LessonPackage

    private func repoFile(_ relative: String) -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url.appendingPathComponent(relative)
    }

    private func config() throws -> LP.JSONValue {
        try LP.JSONValue.parse(Data(contentsOf: repoFile("config/groove_config.json")))
    }

    private func manifestData() throws -> Data {
        try Data(contentsOf: repoFile("fixtures/lessons/example_manifest.json"))
    }

    private func manifest() throws -> LP.Manifest {
        try LP.loadManifest(data: manifestData(), config: config())
    }

    /// The example manifest as a mutable dictionary, re-serialized after `edit`.
    private func mutated(_ edit: (inout [String: Any]) -> Void) throws -> Data {
        var doc = try XCTUnwrap(JSONSerialization.jsonObject(with: manifestData()) as? [String: Any])
        edit(&doc)
        return try JSONSerialization.data(withJSONObject: doc)
    }

    private func errors(_ data: Data) throws -> [String] {
        LP.validateManifest(data: data, config: try config())
    }

    private func assertRejects(_ data: Data, containing needle: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let errs = try errors(data)
        XCTAssertTrue(errs.contains { $0.contains(needle) }, "expected '\(needle)' in \(errs)", file: file, line: line)
    }

    private func referenceFrames() -> [GrooveScoringEngine.RawPoseFrame] {
        (0..<490).map { GrooveScoringEngine.RawPoseFrame(t: Double($0) / 30.0, joints: [:]) }
    }

    // MARK: validation

    func testExampleManifestIsValid() throws {
        XCTAssertEqual(try errors(manifestData()), [])
        let m = try manifest()
        XCTAssertEqual(m.lessonSlug, "img4941-routine")
        XCTAssertEqual(m.segments.count, 5)
        XCTAssertEqual(m.practice.adaptiveSpeed, LP.AdaptiveSpeed.default)
        XCTAssertEqual(m.beatGrid.beats.count, 30)
    }

    func testStructuralRejects() throws {
        try assertRejects(mutated { $0["surprise"] = 1 }, containing: "unexpected field")
        try assertRejects(mutated { $0.removeValue(forKey: "practice") }, containing: "missing required field 'practice'")
        try assertRejects(mutated { $0["schema"] = "groove.lesson/2" }, containing: "expected 'groove.lesson/1'")
        try assertRejects(mutated { $0["course_slug"] = "Bad Slug" }, containing: "course_slug")
        try assertRejects(mutated { $0["package_version"] = 0 }, containing: "package_version")
        try assertRejects(mutated { $0["package_version"] = 1.5 }, containing: "expected integer")
        try assertRejects(mutated {
            var video = $0["video"] as! [String: Any]
            video["mirrored"] = "no"
            $0["video"] = video
        }, containing: "expected boolean")
    }

    func testCrossFieldRules() throws {
        try assertRejects(mutated {
            var segs = $0["segments"] as! [[String: Any]]
            segs[0]["start_s"] = 0.2
            $0["segments"] = segs
        }, containing: "ms of a beat")
        try assertRejects(mutated {
            var segs = $0["segments"] as! [[String: Any]]
            segs[1]["id"] = "A"
            $0["segments"] = segs
        }, containing: "duplicate segment id")
        try assertRejects(mutated {
            var segs = $0["segments"] as! [[String: Any]]
            segs[4]["teach_order"] = 7
            $0["segments"] = segs
        }, containing: "teach_order must be 1..5")
        try assertRejects(mutated {
            var files = $0["files"] as! [String: Any]
            files.removeValue(forKey: "poster.jpg")
            $0["files"] = files
        }, containing: "missing sha256 for 'poster.jpg'")
        try assertRejects(mutated {
            var video = $0["video"] as! [String: Any]
            video["duration_s"] = 10.0
            $0["video"] = video
        }, containing: "video.duration_s")
    }

    func testConfigOverrideKeys() throws {
        try assertRejects(mutated { $0["config_overrides"] = ["scoring_thresholds": ["nope": 1]] }, containing: "not a key of config")
        try assertRejects(mutated {
            $0["config_overrides"] = ["scoring_thresholds": ["gate": ["timing_source": "sometimes"]]]
        }, containing: "timing_source")
        try assertRejects(mutated {
            $0["config_overrides"] = ["scoring_thresholds": ["shape": ["arm_weight": 1.5]]]
        }, containing: "arm_weight")
        try assertRejects(mutated { $0["config_overrides"] = ["version": 3] }, containing: "type differs")
        try assertRejects(mutated { $0["config_overrides"] = ["scoring_thresholds": 3] }, containing: "must be an object")
    }

    func testAdaptivePolicyRules() throws {
        func policy(_ edit: (inout [String: Any]) -> Void) throws -> Data {
            try mutated {
                var practice = $0["practice"] as! [String: Any]
                var p = practice["adaptive_speed"] as! [String: Any]
                edit(&p)
                practice["adaptive_speed"] = p
                $0["practice"] = practice
            }
        }
        try assertRejects(policy { $0["start_rate"] = 0.55 }, containing: "min_rate <= start_rate <= max_rate")
        try assertRejects(policy { $0["unlock_next_at_rate"] = 0.55 }, containing: "unlock_next_at_rate")
        try assertRejects(policy { $0["min_rate"] = 0.3 }, containing: "min_rate")
        try assertRejects(policy { $0["promote_after"] = 0 }, containing: "promote_after")
        try assertRejects(policy { $0.removeValue(forKey: "step_up") }, containing: "step_up")
        XCTAssertThrowsError(try LP.nextRate(
            policy: LP.AdaptiveSpeed(minRate: 0.6, startRate: 0.5, maxRate: 1.0, stepUp: 0.1, stepDown: 0.05,
                                     promoteAfter: 2, demoteAfter: 2, unlockNextAtRate: 0.8),
            history: []
        ))
    }

    // MARK: lookups and merge

    func testTeachingSequenceAndPolicy() throws {
        let m = try manifest()
        XCTAssertEqual(LP.teachingSequence(m), ["A", "B", "C", "D", "full"])
        XCTAssertEqual(try LP.segmentPolicy(m, id: "C"), LP.AdaptiveSpeed.default)
        XCTAssertThrowsError(try LP.segment(m, id: "Z")) { XCTAssertEqual($0 as? LP.Failure, .unknownSegment("Z")) }
    }

    func testSegmentConfigMergeOrder() throws {
        let m = try manifest()
        let base = try config()
        func leaf(_ v: LP.JSONValue, _ path: [String]) -> LP.JSONValue? {
            var cur: LP.JSONValue? = v
            for key in path { cur = cur?.objectValue?[key] }
            return cur
        }
        let a = try LP.segmentConfig(config: base, manifest: m, segmentID: "A")
        let c = try LP.segmentConfig(config: base, manifest: m, segmentID: "C")
        // lesson override applies to every segment
        XCTAssertEqual(leaf(a, ["scoring_thresholds", "shape", "arm_weight"]), .number(0.35))
        XCTAssertEqual(leaf(a, ["scoring_thresholds", "groove", "pass_min_score"]), .number(0))
        // segment C adds the timing source on top
        XCTAssertNil(leaf(a, ["scoring_thresholds", "gate", "timing_source"]))
        XCTAssertEqual(leaf(c, ["scoring_thresholds", "gate", "timing_source"]), .string("hits"))
        XCTAssertEqual(leaf(c, ["scoring_thresholds", "shape", "arm_weight"]), .number(0.35))
        // the bundled config is untouched, and unrelated keys survive
        XCTAssertNil(leaf(base, ["scoring_thresholds", "shape", "arm_weight"]))
        XCTAssertEqual(leaf(a, ["version"]), leaf(base, ["version"]))
        // precedence: segment beats lesson beats bundled
        let lesson = LP.JSONValue.object(["x": .object(["y": .number(1), "z": .number(1)])])
        let seg = LP.JSONValue.object(["x": .object(["y": .number(2)])])
        XCTAssertEqual(
            LP.deepMerge(LP.deepMerge(.object(["x": .object(["y": .number(0), "w": .number(0)])]), lesson), seg),
            .object(["x": .object(["y": .number(2), "z": .number(1), "w": .number(0)])])
        )
    }

    // MARK: slice and stretch (vectors computed with groove_eval.lesson_package)

    func testSliceCounts() throws {
        let m = try manifest()
        let expected: [String: (frames: Int, beats: Int, windows: Int)] = [
            "A": (145, 8, 0), "B": (65, 3, 1), "C": (97, 5, 0), "D": (191, 11, 1)
        ]
        for (id, want) in expected {
            let s = try LP.sliceReference(frames: referenceFrames(), manifest: m, segmentID: id)
            XCTAssertEqual(s.frames.count, want.frames, id)
            XCTAssertEqual(s.beatTimes.count, want.beats, id)
            XCTAssertEqual(s.windows.count, want.windows, id)
        }
    }

    func testSliceCBoundaries() throws {
        let m = try manifest()
        let s = try LP.sliceReference(frames: referenceFrames(), manifest: m, segmentID: "C")
        XCTAssertEqual(s.clipID, "img4941-routine/C")
        XCTAssertEqual(s.moveTag, "C")
        XCTAssertEqual(s.bpm, 112.5)
        XCTAssertEqual(s.speedPct, 100)
        XCTAssertEqual(s.frames.first!.t, -0.2666666666666666, accuracy: 1e-12)
        XCTAssertEqual(s.frames.last!.t, 2.9333333333333336, accuracy: 1e-12)
        let beats = [-0.0030000000000001137, 0.5299999999999994, 1.0629999999999997, 1.5969999999999995, 2.129999999999999]
        XCTAssertEqual(s.beatTimes.count, beats.count)
        for (g, w) in zip(s.beatTimes, beats) { XCTAssertEqual(g, w, accuracy: 1e-12) }
        XCTAssertEqual(s.gravityVector, [0.0, -1.0, 0.0])
        XCTAssertEqual(s.poseClip.frames.count, 97)
    }

    func testStretchMapsToWallClock() throws {
        let m = try manifest()
        let s = try LP.sliceReference(frames: referenceFrames(), manifest: m, segmentID: "C")
        let st = try LP.stretch(s, rate: 0.8)
        XCTAssertEqual(st.frames.first!.t, -0.33333333333333326, accuracy: 1e-12)
        XCTAssertEqual(st.frames.last!.t, 3.666666666666667, accuracy: 1e-12)
        XCTAssertEqual(st.beatTimes[1], 0.6624999999999992, accuracy: 1e-12)
        XCTAssertEqual(st.bpm, 90.0, accuracy: 1e-9)
        XCTAssertEqual(st.speedPct, 80)
        XCTAssertEqual(st.rate, 0.8)
        // rate 1.0 is a copy
        let same = try LP.stretch(s, rate: 1.0)
        XCTAssertEqual(same.frames.map { $0.t }, s.frames.map { $0.t })
        XCTAssertEqual(same.bpm, s.bpm)
        // windows rebase and scale
        let b = try LP.sliceReference(frames: referenceFrames(), manifest: m, segmentID: "B")
        let bs = try LP.stretch(b, rate: 0.5)
        XCTAssertEqual(bs.windows[0].endS, b.windows[0].endS / 0.5, accuracy: 1e-12)
    }

    func testStretchAcceptsEveryRateInThePolicyRangeAndRejectsOthers() throws {
        let m = try manifest()
        let s = try LP.sliceReference(frames: referenceFrames(), manifest: m, segmentID: "A")
        let policy = try LP.segmentPolicy(m, id: "A")
        for pct in 60...100 {
            let r = Double(pct) / 100.0
            XCTAssertEqual(try LP.stretch(s, rate: r, policy: policy).speedPct, pct)
        }
        XCTAssertThrowsError(try LP.stretch(s, rate: 0.59, policy: policy))
        XCTAssertThrowsError(try LP.stretch(s, rate: 1.01, policy: policy))
        XCTAssertNoThrow(try LP.stretch(s, rate: 0.5))
        XCTAssertThrowsError(try LP.stretch(s, rate: 0.49))
    }

    // MARK: adaptive speed (vectors computed with groove_eval.lesson_package.next_rate)

    private func takes(_ bits: [Int]) -> [LP.Take] { bits.map { LP.Take(passed: $0 == 1) } }

    func testNextRateVectors() throws {
        let p = LP.AdaptiveSpeed.default
        let vectors: [([Int], Double, Bool)] = [
            ([], 0.7, false),
            ([1, 1], 0.8, false),
            ([1, 1, 1, 1], 0.9, true),
            ([0, 0], 0.65, false),
            ([0, 0, 0, 0, 0, 0], 0.6, false),
            ([1, 1, 1, 1, 1, 1], 1.0, true),
            ([0, 1, 0, 1], 0.7, false),
            ([1, 1, 1, 1, 0, 0], 0.85, true)
        ]
        for (bits, rate, unlocked) in vectors {
            let got = try LP.nextRate(policy: p, history: takes(bits))
            XCTAssertEqual(got.rate, rate, accuracy: 1e-12, "\(bits)")
            XCTAssertEqual(got.unlocked, unlocked, "\(bits)")
        }
    }

    func testTakeAtAnotherRateMovesTheLadder() throws {
        let p = LP.AdaptiveSpeed.default
        let two = try LP.nextRate(policy: p, history: [LP.Take(passed: true, rate: 0.9), LP.Take(passed: true, rate: 0.9)])
        XCTAssertEqual(two.rate, 1.0, accuracy: 1e-12)
        XCTAssertTrue(two.unlocked)
        let one = try LP.nextRate(policy: p, history: [LP.Take(passed: true, rate: 0.8)])
        XCTAssertEqual(one.rate, 0.8, accuracy: 1e-12)
        XCTAssertTrue(one.unlocked)
        XCTAssertEqual(LP.quantizeRate(0.7 + 0.1), 0.8)
    }
}
