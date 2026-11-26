import XCTest
@testable import GrooveCore

final class CalibrationGateTests: XCTestCase {

    // MARK: - Fixtures

    /// Gravity for a phone with the given signed roll and lean-back (degrees) in front-camera mode.
    private func gravity(roll: Double = 0, tiltBack: Double = 0) -> CalibrationVector3 {
        let tr = tan(roll * .pi / 180)
        let tt = tan(tiltBack * .pi / 180)
        let c = 1 / (1 + tr * tr + tt * tt).squareRoot()
        return CalibrationVector3(x: tr * c, y: -c, z: -tt * c)
    }

    private func motion(_ t: Double, roll: Double = 0, tiltBack: Double = 0,
                        accel: Double = 0, rot: Double = 0) -> CalibrationMotionSample {
        CalibrationMotionSample(timestamp: t, gravity: gravity(roll: roll, tiltBack: tiltBack),
                                userAcceleration: CalibrationVector3(x: accel, y: 0, z: 0),
                                rotationRate: CalibrationVector3(x: 0, y: rot, z: 0))
    }

    /// A synthetic dancer in raw (un-mirrored) normalised image coords, y down. Their own left is image right.
    private struct Body {
        var dx = 0.0
        var dy = 0.0
        var scale = 1.0
        var tpose = false
        var visibility: [String: Double] = [:]
        var defaultVisibility = 0.95
    }

    private static let standing: [String: (Double, Double)] = [
        "nose": (0.50, 0.25),
        "leftShoulder": (0.56, 0.33), "rightShoulder": (0.44, 0.33),
        "leftElbow": (0.58, 0.45), "rightElbow": (0.42, 0.45),
        "leftWrist": (0.59, 0.55), "rightWrist": (0.41, 0.55),
        "leftHip": (0.54, 0.55), "rightHip": (0.46, 0.55),
        "leftKnee": (0.54, 0.70), "rightKnee": (0.46, 0.70),
        "leftAnkle": (0.54, 0.84), "rightAnkle": (0.46, 0.84),
        "leftHeel": (0.54, 0.86), "rightHeel": (0.46, 0.86),
        "leftFootIndex": (0.55, 0.88), "rightFootIndex": (0.45, 0.88)
    ]

    private static let tArms: [String: (Double, Double)] = [
        "leftElbow": (0.66, 0.33), "rightElbow": (0.34, 0.33),
        "leftWrist": (0.76, 0.33), "rightWrist": (0.24, 0.33)
    ]

    private static let base3D: [String: [Double]] = [
        "root": [0.0, 0.0, 0.0],
        "spine": [0.0, 0.24, 0.0],
        "centerShoulder": [0.0, 0.48, 0.0],
        "nose": [0.0, 0.69, 0.0],
        "leftHip": [0.10, 0.0, 0.0],
        "leftKnee": [0.10, -0.45, 0.0],
        "leftAnkle": [0.10, -0.84, 0.0],
        "leftHeel": [0.10, -0.87, -0.07],
        "leftFootIndex": [0.10, -0.87, 0.16],
        "rightHip": [-0.10, 0.0, 0.0],
        "rightKnee": [-0.10, -0.45, 0.0],
        "rightAnkle": [-0.10, -0.84, 0.0],
        "rightHeel": [-0.10, -0.87, -0.07],
        "rightFootIndex": [-0.10, -0.87, 0.16],
        "leftShoulder": [0.19, 0.48, 0.0],
        "leftElbow": [0.22, 0.20, 0.0],
        "leftWrist": [0.24, -0.06, 0.0],
        "rightShoulder": [-0.19, 0.48, 0.0],
        "rightElbow": [-0.22, 0.20, 0.0],
        "rightWrist": [-0.24, -0.06, 0.0]
    ]

    private func named(_ b: Body) -> [String: CalibrationLandmark] {
        var out: [String: CalibrationLandmark] = [:]
        for (name, p) in Self.standing {
            let q = b.tpose ? (Self.tArms[name] ?? p) : p
            let x = 0.5 + (q.0 - 0.5) * b.scale + b.dx
            let y = 0.55 + (q.1 - 0.55) * b.scale + b.dy
            out[name] = CalibrationLandmark(x: x, y: y, visibility: b.visibility[name] ?? b.defaultVisibility)
        }
        return out
    }

    private func rawFrame(_ t: Double) -> GrooveScoringEngine.RawPoseFrame {
        GrooveScoringEngine.RawPoseFrame(t: t, joints: [
            "root": [0, 0, 0], "leftHip": [0.1, 0, 0], "rightHip": [-0.1, 0, 0],
            "leftKnee": [0.1, -0.45, 0], "rightKnee": [-0.1, -0.45, 0]
        ])
    }

    private func pose(_ t: Double, _ b: Body = Body()) -> CalibrationPoseSample {
        CalibrationPoseSample(timestamp: t, named: named(b), frame: rawFrame(t))
    }

    /// Builds a valid synthetic sample matching whichever pose `step` is active so multi-step tests can walk Poses 1–9.
    private func poseForStep(_ t: Double, step: CalibrationStep) -> CalibrationPoseSample {
        var pts2D = Self.standing
        var j3D = Self.base3D

        switch step {
        case .resume, .level, .rest, .locked:
            break
        case .tpose:
            for (k, v) in Self.tArms { pts2D[k] = v }
            j3D["leftElbow"] = [0.47, 0.48, 0.0]
            j3D["leftWrist"] = [0.73, 0.48, 0.0]
            j3D["rightElbow"] = [-0.47, 0.48, 0.0]
            j3D["rightWrist"] = [-0.73, 0.48, 0.0]
        case .overhead:
            pts2D["leftElbow"] = (0.57, 0.19)
            pts2D["rightElbow"] = (0.43, 0.19)
            pts2D["leftWrist"] = (0.57, 0.08)
            pts2D["rightWrist"] = (0.43, 0.08)
            j3D["leftElbow"] = [0.21, 0.75, 0.0]
            j3D["leftWrist"] = [0.22, 1.00, 0.0]
            j3D["rightElbow"] = [-0.21, 0.75, 0.0]
            j3D["rightWrist"] = [-0.22, 1.00, 0.0]
        case .asymLR:
            pts2D["leftElbow"] = (0.57, 0.20)
            pts2D["leftWrist"] = (0.57, 0.09)
            pts2D["rightElbow"] = (0.34, 0.33)
            pts2D["rightWrist"] = (0.24, 0.33)
            j3D["leftElbow"] = [0.20, 0.75, 0.0]
            j3D["leftWrist"] = [0.21, 1.00, 0.0]
            j3D["rightElbow"] = [-0.47, 0.48, 0.0]
            j3D["rightWrist"] = [-0.73, 0.48, 0.0]
        case .armsForward:
            pts2D["leftElbow"] = (0.56, 0.35)
            pts2D["rightElbow"] = (0.44, 0.35)
            pts2D["leftWrist"] = (0.56, 0.34)
            pts2D["rightWrist"] = (0.44, 0.34)
            j3D["leftElbow"] = [0.19, 0.46, 0.26]
            j3D["leftWrist"] = [0.19, 0.46, 0.50]
            j3D["rightElbow"] = [-0.19, 0.46, 0.26]
            j3D["rightWrist"] = [-0.19, 0.46, 0.50]
        case .plie:
            pts2D["leftElbow"] = (0.66, 0.36)
            pts2D["rightElbow"] = (0.34, 0.36)
            pts2D["leftWrist"] = (0.76, 0.36)
            pts2D["rightWrist"] = (0.24, 0.36)
            pts2D["leftHip"] = (0.54, 0.59)
            pts2D["rightHip"] = (0.46, 0.59)
            pts2D["leftKnee"] = (0.56, 0.72)
            pts2D["rightKnee"] = (0.44, 0.72)
            j3D["leftElbow"] = [0.47, 0.48, 0.0]
            j3D["leftWrist"] = [0.73, 0.48, 0.0]
            j3D["rightElbow"] = [-0.47, 0.48, 0.0]
            j3D["rightWrist"] = [-0.73, 0.48, 0.0]
            j3D["leftKnee"] = [0.16, -0.38, 0.14]
            j3D["leftAnkle"] = [0.10, -0.76, 0.0]
            j3D["leftHeel"] = [0.10, -0.79, -0.07]
            j3D["leftFootIndex"] = [0.10, -0.79, 0.16]
            j3D["rightKnee"] = [-0.16, -0.38, 0.14]
            j3D["rightAnkle"] = [-0.10, -0.76, 0.0]
            j3D["rightHeel"] = [-0.10, -0.79, -0.07]
            j3D["rightFootIndex"] = [-0.10, -0.79, 0.16]
        case .turned45:
            pts2D["leftShoulder"] = (0.542, 0.33)
            pts2D["rightShoulder"] = (0.458, 0.33)
            pts2D["leftElbow"] = (0.63, 0.33)
            pts2D["rightElbow"] = (0.37, 0.33)
            pts2D["leftWrist"] = (0.72, 0.33)
            pts2D["rightWrist"] = (0.28, 0.33)
            j3D["leftShoulder"] = [0.134, 0.48, -0.134]
            j3D["rightShoulder"] = [-0.134, 0.48, 0.134]
            j3D["leftElbow"] = [0.33, 0.48, -0.33]
            j3D["leftWrist"] = [0.51, 0.48, -0.51]
            j3D["rightElbow"] = [-0.33, 0.48, 0.33]
            j3D["rightWrist"] = [-0.51, 0.48, 0.51]
        case .stepLeft:
            for (k, v) in pts2D { pts2D[k] = (v.0 + 0.15, v.1) }
        case .stepRight:
            for (k, v) in pts2D { pts2D[k] = (v.0 - 0.15, v.1) }
        case .kneeLift:
            pts2D["leftKnee"] = (0.55, 0.56)
            pts2D["leftAnkle"] = (0.54, 0.68)
            pts2D["leftHeel"] = (0.54, 0.70)
            pts2D["leftFootIndex"] = (0.55, 0.71)
            j3D["leftKnee"] = [0.10, -0.02, 0.43]
            j3D["leftAnkle"] = [0.10, -0.42, 0.41]
            j3D["leftHeel"] = [0.10, -0.45, 0.35]
            j3D["leftFootIndex"] = [0.10, -0.45, 0.55]
        }

        let lm = pts2D.mapValues { CalibrationLandmark(x: $0.0, y: $0.1, visibility: 0.95) }
        let frame = GrooveScoringEngine.RawPoseFrame(t: t, joints: j3D)
        return CalibrationPoseSample(timestamp: t, named: lm, frame: frame)
    }

    @discardableResult
    private func finishRemainingPoses(_ g: inout CalibrationGate, from t0: Double, hz: Double = 30) -> Double {
        var t = t0
        var safety = 0
        while g.step != .locked && safety < 600 {
            g.update(pose: poseForStep(t, step: g.step))
            t += 1.0 / hz
            safety += 1
        }
        XCTAssertEqual(g.step, .locked)
        return t
    }

    /// Feeds `seconds` of pose samples at `hz` starting at `t0`; returns the time after the last sample.
    @discardableResult
    private func feed(_ g: inout CalibrationGate, from t0: Double, seconds: Double, hz: Double = 30,
                      body: (Double) -> Body = { _ in Body() },
                      each: ((Double, CalibrationStatus) -> Void)? = nil) -> Double {
        let n = Int((seconds * hz).rounded())
        for i in 0..<n {
            let t = t0 + Double(i) / hz
            let s = g.update(pose: pose(t, body(t)))
            each?(t, s)
        }
        return t0 + Double(n) / hz
    }

    /// A gate whose phone step has passed (motion clock 0...0.6 s).
    private func leveledGate(tuning: CalibrationTuning = .defaults) -> CalibrationGate {
        var g = CalibrationGate(tuning: tuning)
        for i in 0...18 { g.update(motion: motion(Double(i) / 30)) }
        XCTAssertEqual(g.step, .frame)
        return g
    }

    /// A gate in the T-pose step; returns the next pose time.
    private func tposeGate(tuning: CalibrationTuning = .defaults) -> (CalibrationGate, Double) {
        var g = leveledGate(tuning: tuning)
        let t = feed(&g, from: 100, seconds: 0.7)
        XCTAssertEqual(g.step, .tpose)
        XCTAssertEqual(g.cue, .armsOutT)
        return (g, t)
    }

    // MARK: - Angles

    func testAngleSignConvention() {
        let upright = CalibrationGate.angles(gravity: CalibrationVector3(x: 0, y: -1, z: 0))
        XCTAssertEqual(upright.rollDeg, 0, accuracy: 1e-9)
        XCTAssertEqual(upright.tiltBackDeg, 0, accuracy: 1e-9)
        // Leaning back toward face-up (g -> (0, 0, -1)) is positive in front-camera mode.
        let back = CalibrationGate.angles(gravity: gravity(tiltBack: 30))
        XCTAssertEqual(back.tiltBackDeg, 30, accuracy: 1e-9)
        XCTAssertGreaterThan(CalibrationGate.angles(gravity: CalibrationVector3(x: 0, y: -0.5, z: -0.866)).tiltBackDeg, 0)
        XCTAssertEqual(CalibrationGate.angles(gravity: gravity(tiltBack: -10)).tiltBackDeg, -10, accuracy: 1e-9)
        XCTAssertEqual(CalibrationGate.angles(gravity: gravity(roll: 4)).rollDeg, 4, accuracy: 1e-9)
    }

    // MARK: - Step 1

    func testLevelStepCues() {
        var g = CalibrationGate()
        XCTAssertEqual(g.step, .level)
        XCTAssertEqual(g.cue, .placePhone)
        XCTAssertEqual(g.update(motion: motion(0, roll: 10)).cue, .levelPhone)
        XCTAssertEqual(g.update(motion: motion(0.1, tiltBack: 30)).cue, .tiltLessBack)
        XCTAssertEqual(g.update(motion: motion(0.2, tiltBack: -10)).cue, .tiltLessForward)
        XCTAssertEqual(g.update(motion: motion(0.3, accel: 0.1)).cue, .setPhoneDown)
        XCTAssertEqual(g.update(motion: motion(0.4, rot: 0.2)).cue, .setPhoneDown)
        let s = g.update(motion: motion(0.5, tiltBack: 15))
        XCTAssertEqual(s.cue, .none)
        XCTAssertEqual(s.step, .level)
        XCTAssertEqual(s.progress, 0)
        let tel = g.telemetry()
        XCTAssertEqual(tel.rollOK, true)
        XCTAssertEqual(tel.tiltOK, true)
        XCTAssertEqual(tel.phoneStillOK, true)
        XCTAssertEqual(tel.tiltBackDeg ?? 0, 15, accuracy: 1e-9)
    }

    func testRollHysteresis() {
        var g = CalibrationGate()
        XCTAssertEqual(g.update(motion: motion(0.00, roll: 4)).cue, .levelPhone, "4 deg is above the 3 deg enter limit")
        XCTAssertEqual(g.update(motion: motion(0.05, roll: 2)).cue, .none)
        XCTAssertEqual(g.update(motion: motion(0.10, roll: 4)).cue, .none, "4 deg is inside the 5 deg exit limit once level")
        XCTAssertEqual(g.update(motion: motion(0.15, roll: -4.9)).cue, .none)
        XCTAssertEqual(g.update(motion: motion(0.20, roll: 6)).cue, .levelPhone)
        XCTAssertEqual(g.update(motion: motion(0.25, roll: 4)).cue, .levelPhone, "level lost: back to the enter limit")
    }

    func testPhoneHoldFillsAndResetsOnMotion() {
        var g = CalibrationGate()
        for i in 0...9 { g.update(motion: motion(Double(i) / 30)) }   // 0 ... 0.3 s still
        XCTAssertEqual(g.progress, 0.6, accuracy: 1e-9)
        let bumped = g.update(motion: motion(10.0 / 30, accel: 0.1))
        XCTAssertEqual(bumped.progress, 0)
        XCTAssertEqual(bumped.cue, .setPhoneDown)
        XCTAssertEqual(bumped.step, .level)
        for i in 11...25 { g.update(motion: motion(Double(i) / 30)) }  // 0.367 ... 0.833 s: 0.467 s held
        XCTAssertEqual(g.step, .level)
        g.update(motion: motion(27.0 / 30))                              // 0.533 s held
        XCTAssertEqual(g.step, .frame)
        XCTAssertNotNil(g.lockedGravity)
    }

    // MARK: - Step 2

    func testFramingCues() {
        let base = leveledGate()
        func cue(_ b: Body, tuning: CalibrationTuning = .defaults) -> CalibrationCue {
            var g = base
            g.tuning = tuning
            return g.update(pose: pose(100, b)).cue
        }
        XCTAssertEqual(cue(Body()), .none)
        XCTAssertEqual(cue(Body(defaultVisibility: 0)), .stepIn)
        XCTAssertEqual(cue(Body(visibility: ["leftHeel": 0.3])), .stepBackShowFeet)
        XCTAssertEqual(cue(Body(visibility: ["rightAnkle": 0.3])), .stepBackShowFeet)
        XCTAssertEqual(cue(Body(visibility: ["nose": 0.3])), .showHead)
        XCTAssertEqual(cue(Body(visibility: ["leftHip": 0.3])), .stepBack)
        XCTAssertEqual(cue(Body(dy: 0.09)), .stepBackShowFeet, "feet below maxFootY")
        XCTAssertEqual(cue(Body(dy: -0.07)), .stepBack, "no headroom above the nose")
        XCTAssertEqual(cue(Body(scale: 0.3)), .stepCloser)
        var tight = CalibrationTuning.defaults
        tight.spanMax = 0.55
        XCTAssertEqual(cue(Body(), tuning: tight), .stepBack, "span above spanMax")
        // Mirrored phrasing: raw x < 0.5 is the dancer's own right, so they move to their left.
        XCTAssertEqual(cue(Body(dx: -0.25)), .moveLeft)
        XCTAssertEqual(cue(Body(dx: 0.25)), .moveRight)
        XCTAssertEqual(cue(Body(dx: -0.43)), .moveLeft, "outside the safe box")
        XCTAssertEqual(cue(Body(dx: 0.43)), .moveRight, "outside the safe box")

        var g = base
        g.update(pose: pose(100, Body(dx: -0.43)))
        let tel = g.telemetry()
        XCTAssertEqual(tel.safeBoxOK, false)
        XCTAssertEqual(tel.centredOK, false)
        XCTAssertEqual(tel.presenceOK, true)
        XCTAssertEqual(tel.framingOK, false)
        XCTAssertEqual(tel.framingCue, CalibrationCue.moveLeft.rawValue)
        XCTAssertEqual(tel.span ?? 0, 0.63, accuracy: 1e-9)
    }

    func testFramingHoldResetsAndUsesHysteresis() {
        var g = leveledGate()
        var t = feed(&g, from: 100, seconds: 0.3)
        XCTAssertEqual(g.step, .frame)
        XCTAssertGreaterThan(g.progress, 0.3)
        // A sustained failure beyond dropoutToleranceS resets the hold.
        t = feed(&g, from: t, seconds: 0.45, body: { _ in Body(dx: 0.25) })
        XCTAssertEqual(g.progress, 0)
        // Feet at 0.45 fail the 0.5 enter floor ...
        XCTAssertEqual(g.update(pose: pose(t, Body(visibility: ["leftHeel": 0.45]))).cue, .stepBackShowFeet)
        t += 1.0 / 30
        // ... but once framing latches, the 0.4 hold floor keeps it passing.
        XCTAssertEqual(g.update(pose: pose(t, Body())).cue, .none)
        t += 1.0 / 30
        t = feed(&g, from: t, seconds: 0.7, body: { _ in Body(visibility: ["leftHeel": 0.45]) })
        XCTAssertEqual(g.step, .tpose)
        XCTAssertEqual(g.telemetry().footFloorUsed ?? 0, 0.4, accuracy: 1e-9)
    }

    func testRelaxAfter15Seconds() {
        var g = leveledGate()
        let weakFeet = Body(visibility: ["leftHeel": 0.45, "rightFootIndex": 0.45])
        var lastBefore: CalibrationStatus?
        feed(&g, from: 100, seconds: 16, body: { _ in weakFeet }, each: { t, s in
            if t < 114.95 { lastBefore = s }
        })
        XCTAssertEqual(lastBefore?.step, .frame)
        XCTAssertEqual(lastBefore?.cue, .stepBackShowFeet)
        XCTAssertEqual(lastBefore?.relaxed, false)
        XCTAssertTrue(g.relaxed)
        XCTAssertEqual(g.step, .tpose)
        XCTAssertTrue(g.telemetry().relaxed)
    }

    func testBumpAfterPlacementDropsBackToLevel() {
        var g = leveledGate()
        feed(&g, from: 100, seconds: 0.2)
        XCTAssertEqual(g.update(motion: motion(1.0, tiltBack: 1)).step, .frame, "small wobble is tolerated")
        let s = g.update(motion: motion(1.1, tiltBack: 10))
        XCTAssertEqual(s.step, .level)
        XCTAssertEqual(s.cue, .none, "10 deg is inside the tilt window; the phone hold restarts")
        XCTAssertNil(g.lockedGravity)
    }

    // MARK: - Step 3 (lighting)

    func testLightAdvice() {
        func advice(_ l: CalibrationLightSample, person: Bool = true) -> CalibrationLightAdvice {
            CalibrationGate.lightAdvice(l, personPresent: person)
        }
        let good = CalibrationLightSample(meanLuma: 0.5, torsoLuma: 0.45, borderLuma: 0.5,
                                          iso: 100, maxISO: 2000, exposureSeconds: 0.01)
        XCTAssertEqual(advice(good), .ok)
        var l = good; l.meanLuma = 0.2
        XCTAssertEqual(advice(l), .dim)
        l = good; l.exposureSeconds = 0.04
        XCTAssertEqual(advice(l), .dim)
        l = good; l.iso = 500
        XCTAssertEqual(advice(l), .dim)
        l = good; l.iso = 300; l.maxISO = 350
        XCTAssertEqual(advice(l), .dim, "iso / maxISO >= 0.8")
        l = good; l.torsoLuma = 0.1; l.borderLuma = 0.6
        XCTAssertEqual(advice(l), .backlit)
        l = good; l.meanLuma = 0.05
        XCTAssertEqual(advice(l, person: false), .veryDark)
        XCTAssertEqual(advice(l, person: true), .dim)
        XCTAssertEqual(CalibrationLightAdvice.dim.cue, .dimLight)
        XCTAssertEqual(CalibrationLightAdvice.backlit.cue, .backlit)
        XCTAssertEqual(CalibrationLightAdvice.veryDark.cue, .veryDark)
        XCTAssertEqual(CalibrationLightAdvice.ok.cue, .none)
    }

    func testLightingNeverBlocks() {
        let samples = [
            CalibrationLightSample(meanLuma: 0.05, iso: 2000, maxISO: 2000, exposureSeconds: 0.05),
            CalibrationLightSample(meanLuma: 0.4, torsoLuma: 0.1, borderLuma: 0.7, iso: 100, maxISO: 2000,
                                   exposureSeconds: 0.01)
        ]
        var g = CalibrationGate()
        g.update(light: samples[0])
        XCTAssertEqual(g.lightAdvice, .veryDark, "no person yet")
        XCTAssertEqual(g.status.lightCue, .veryDark)
        for i in 0...18 {
            g.update(motion: motion(Double(i) / 30))
            g.update(light: samples[i % 2])
        }
        XCTAssertEqual(g.step, .frame)
        // Light samples every 0.5 s alternate dim / backlit while the dancer completes Poses 1–9.
        var advices = Set<CalibrationLightAdvice>()
        var i = 0
        while g.step != .locked && i < 300 {
            let t = 100 + Double(i) / 30
            g.update(pose: poseForStep(t, step: g.step))
            if i % 15 == 0 { advices.insert(g.update(light: samples[(i / 15) % 2]).lightAdvice) }
            i += 1
        }
        XCTAssertEqual(g.step, .locked)
        XCTAssertLessThan(i, 250, "locks as fast as with good light")
        XCTAssertEqual(advices, [.dim, .backlit], "very dark with a person present reads as dim")
        XCTAssertEqual(g.telemetry().lightOK, false)
    }

    // MARK: - Step 4

    func testTPoseScore() {
        let t = CalibrationGate.tPoseScore(pose(0, Body(tpose: true)))
        XCTAssertEqual(t.score, 1, accuracy: 1e-9)
        XCTAssertTrue(t.passes)
        let down = CalibrationGate.tPoseScore(pose(0, Body()))
        XCTAssertFalse(down.passes)
        XCTAssertLessThan(down.score, 0.55)
        XCTAssertLessThanOrEqual(down.sY, 0.3)
    }

    func testTPoseCuesAndLock() {
        var (g, t) = tposeGate()
        XCTAssertEqual(g.update(pose: pose(t, Body())).cue, .armsOutT)
        t += 1.0 / 30
        var sawHalf = false
        t = feed(&g, from: t, seconds: 1.2, body: { _ in Body(tpose: true) }, each: { _, s in
            if s.step == .tpose {
                XCTAssertEqual(s.cue, .holdStill)
                XCTAssertLessThan(s.progress, 1)
                if s.progress > 0.5 { sawHalf = true }
            }
        })
        XCTAssertTrue(sawHalf)
        XCTAssertEqual(g.step, .overhead)
        t = finishRemainingPoses(&g, from: t)
        XCTAssertEqual(g.step, .locked)
        XCTAssertEqual(g.cue, .locked)
        XCTAssertEqual(g.progress, 1)
        let frames = try! XCTUnwrap(g.calibrationFrames)
        XCTAssertGreaterThanOrEqual(frames.count, 15)
        XCTAssertEqual(g.lockedProfile?.gravity.count, 3)
        XCTAssertEqual(g.lockedGravity?[1] ?? 0, -1, accuracy: 1e-9)
        // Locked frames feed Retarget like any calibration stance.
        let clip = GrooveScoringEngine.PoseClip(clip_id: "c", move_tag: "m", bpm: 100, beat_times: [],
                                                gravity_vector: g.lockedGravity, frames: [],
                                                calibration_frames: g.calibrationFrames)
        XCTAssertEqual(GrooveScoringEngine.Retarget.learnerBoneLengths(attempt: clip)["leftKnee"] ?? 0, 0.45,
                       accuracy: 1e-9)
        // Further samples do not change a locked gate.
        XCTAssertEqual(g.update(pose: pose(t, Body(dx: 0.3))).step, .locked)
        XCTAssertEqual(g.update(motion: motion(5, roll: 30)).step, .locked)
    }

    func testLockWaitsForMinFramesAtLowFrameRate() {
        var (g, t) = tposeGate()
        var tPoseDoneAt: Double?
        let nextT = feed(&g, from: t, seconds: 1.6, hz: 10, body: { _ in Body(tpose: true) }, each: { time, s in
            if s.step == .overhead && tPoseDoneAt == nil { tPoseDoneAt = time }
        })
        let completedAt = try! XCTUnwrap(tPoseDoneAt)
        XCTAssertEqual(completedAt - t, 1.4, accuracy: 1e-6, "1.0 s at 10 Hz is 11 samples; waits for the 15th")
        XCTAssertEqual(g.capturedFrames.count, 15)
        XCTAssertEqual(g.telemetry().capturedFrameCount, 15)
        finishRemainingPoses(&g, from: nextT)
        XCTAssertEqual(g.calibrationFrames?.count, 15)
    }

    func testTPoseDropoutToleranceKeepsHold() {
        var (g, t) = tposeGate()
        let start = t
        let gap = 12...19   // samples 0.40 ... 0.63 s: arms down, 0.30 s between good samples
        func index(_ time: Double) -> Int { Int(((time - start) * 30).rounded()) }
        var minProgressInGap = 1.0
        let nextT = feed(&g, from: t, seconds: 1.1, body: { time in
            Body(tpose: !gap.contains(index(time)))
        }, each: { time, s in
            if gap.contains(index(time)) {
                XCTAssertEqual(s.step, .tpose)
                minProgressInGap = min(minProgressInGap, s.progress)
            }
        })
        XCTAssertGreaterThan(minProgressInGap, 0.3, "progress survives the dropout")
        XCTAssertEqual(g.step, .overhead)
        // Frames during the dropout are not captured: 1.0 s hold at 30 Hz = 31 samples minus the 8 dropped.
        XCTAssertEqual(g.capturedFrames.count, 23)
        finishRemainingPoses(&g, from: nextT)
        XCTAssertEqual(g.calibrationFrames?.count, 23)
    }

    func testTPoseDropoutBeyondToleranceResets() {
        var (g, t) = tposeGate()
        t = feed(&g, from: t, seconds: 0.5, body: { _ in Body(tpose: true) })
        XCTAssertGreaterThan(g.progress, 0.4)
        var progressAfter = 1.0
        t = feed(&g, from: t, seconds: 0.5, body: { _ in Body() }, each: { _, s in progressAfter = s.progress })
        XCTAssertEqual(progressAfter, 0)
        XCTAssertEqual(g.cue, .armsOutT)
        XCTAssertEqual(g.capturedFrames.count, 0)
        // The hold starts again from zero.
        t = feed(&g, from: t, seconds: 0.9, body: { _ in Body(tpose: true) })
        XCTAssertEqual(g.step, .tpose)
        feed(&g, from: t, seconds: 0.2, body: { _ in Body(tpose: true) })
        XCTAssertEqual(g.step, .overhead)
    }

    func testTPoseHoldResetsOnBodyMotion() {
        var (g, t) = tposeGate()
        t = feed(&g, from: t, seconds: 0.5, body: { _ in Body(tpose: true) })
        XCTAssertGreaterThan(g.progress, 0.4)
        // Swaying 0.02 per sample (about 0.03 body spans) for 0.5 s: past the 0.02 stay limit and the dropout.
        var k = 0
        t = feed(&g, from: t, seconds: 0.5, body: { _ in
            k += 1
            return Body(dx: k % 2 == 0 ? 0.01 : -0.01, tpose: true)
        })
        XCTAssertEqual(g.step, .tpose)
        XCTAssertEqual(g.progress, 0)
        XCTAssertEqual(g.cue, .holdStill, "the T is fine, the body is moving")
        XCTAssertEqual(g.telemetry().bodyStillOK, false)
        t = feed(&g, from: t, seconds: 0.9, body: { _ in Body(tpose: true) })
        XCTAssertEqual(g.step, .tpose, "a fresh 1.0 s hold is needed")
        feed(&g, from: t, seconds: 0.3, body: { _ in Body(tpose: true) })
        XCTAssertEqual(g.step, .overhead)
    }

    func testFramingLossDuringTPose() {
        var (g, t) = tposeGate()
        t = feed(&g, from: t, seconds: 0.3, body: { _ in Body(tpose: true) })
        // 0.2 s off-centre is tolerated ...
        t = feed(&g, from: t, seconds: 0.2, body: { _ in Body(dx: -0.25, tpose: true) })
        XCTAssertEqual(g.step, .tpose)
        t = feed(&g, from: t, seconds: 0.1, body: { _ in Body(tpose: true) })
        // ... 0.5 s is not: back to framing with the framing cue.
        feed(&g, from: t, seconds: 0.5, body: { _ in Body(dx: -0.25, tpose: true) })
        XCTAssertEqual(g.step, .frame)
        XCTAssertEqual(g.cue, .moveLeft)
        XCTAssertEqual(g.capturedFrames.count, 0)
    }

    // MARK: - Skip, resume, live tuning

    func testSkip() {
        var g = CalibrationGate()
        g.update(motion: motion(0, roll: 20))
        g.skip()
        XCTAssertEqual(g.step, .locked)
        XCTAssertTrue(g.skipped)
        XCTAssertTrue(g.status.skipped)
        XCTAssertNil(g.calibrationFrames)
        XCTAssertNil(g.lockedProfile)
        XCTAssertNil(g.lockedProfileV2)
        XCTAssertEqual(g.lockedGravity?.count, 3)
        XCTAssertEqual(g.update(pose: pose(1, Body(tpose: true))).step, .locked)
        XCTAssertTrue(g.telemetry().skipped)

        // Skip from the T-pose step drops the partial capture.
        var (h, t) = tposeGate()
        feed(&h, from: t, seconds: 0.5, body: { _ in Body(tpose: true) })
        XCTAssertGreaterThan(h.capturedFrames.count, 0)
        h.skip()
        XCTAssertNil(h.calibrationFrames)
        XCTAssertEqual(h.capturedFrames.count, 0)

        h.reset()
        XCTAssertEqual(h.step, .level)
        XCTAssertFalse(h.skipped)
    }

    func testResumeReusesProfileWhenPhoneHasNotMoved() {
        let profile = CalibrationProfile(frames: [rawFrame(0), rawFrame(1), rawFrame(2)], gravity: [0, -1, 0])
        var g = CalibrationGate(resume: profile)
        XCTAssertEqual(g.step, .resume)
        XCTAssertEqual(g.cue, .none)
        g.update(motion: motion(0, tiltBack: 1))   // about 0.017 g away
        XCTAssertEqual(g.step, .frame)
        XCTAssertEqual(g.telemetry().resumeOK, true)
        feed(&g, from: 50, seconds: 0.5)
        XCTAssertEqual(g.step, .locked, "framing only, no T-pose")
        XCTAssertTrue(g.resumed)
        XCTAssertEqual(g.calibrationFrames?.count, 3)

        var moved = CalibrationGate(resume: profile)
        XCTAssertEqual(moved.update(motion: motion(0, roll: 10)).step, .level)
        XCTAssertEqual(moved.cue, .levelPhone)
        XCTAssertEqual(moved.telemetry().resumeOK, false)
    }

    func testTuningSwapMidFlowKeepsProgress() throws {
        // Step 1: a looser roll limit applies from the next sample without restarting anything.
        var g = CalibrationGate()
        XCTAssertEqual(g.update(motion: motion(0, roll: 10)).cue, .levelPhone)
        g.tuning = try g.tuning.merged(withJSON: Data(#"{"rollEnterDeg": 12, "rollExitDeg": 14}"#.utf8))
        XCTAssertEqual(g.update(motion: motion(0.1, roll: 10)).cue, .none)

        // Step 4: shorten the hold mid-way; progress continues and T-pose completes sooner.
        var (h, t) = tposeGate()
        t = feed(&h, from: t, seconds: 0.5, body: { _ in Body(tpose: true) })
        let before = h.progress
        XCTAssertEqual(before, 0.48, accuracy: 0.02)
        XCTAssertEqual(h.step, .tpose)
        h.tuning.poseHoldS = 0.6
        h.tuning.minCapturedFrames = 5
        let s = h.update(pose: pose(t, Body(tpose: true)))
        XCTAssertGreaterThan(s.progress, before, "progress is not reset by a tuning swap")
        t += 1.0 / 30
        feed(&h, from: t, seconds: 0.2, body: { _ in Body(tpose: true) })
        XCTAssertEqual(h.step, .overhead)
        XCTAssertGreaterThanOrEqual(h.capturedFrames.count, 5)
    }

    // MARK: - Tuning decode

    func testPartialJSONTuningDecode() throws {
        let json = #"{"_comment": "edit me", "_rollEnterDeg": 99, "rollEnterDeg": 2.5, "minCapturedFrames": 20, "notAKey": true, "spanMax": null}"#
        let t = try JSONDecoder().decode(CalibrationTuning.self, from: Data(json.utf8))
        var expected = CalibrationTuning.defaults
        expected.rollEnterDeg = 2.5
        expected.minCapturedFrames = 20
        XCTAssertEqual(t, expected)

        XCTAssertEqual(try JSONDecoder().decode(CalibrationTuning.self, from: Data("{}".utf8)), .defaults)

        // merged(withJSON:) falls back to the receiver, not to the defaults.
        var base = CalibrationTuning.defaults
        base.spanMin = 0.5
        let merged = try base.merged(withJSON: Data(#"{"spanMax": 0.8, "minCapturedFrames": 12.0}"#.utf8))
        XCTAssertEqual(merged.spanMin, 0.5)
        XCTAssertEqual(merged.spanMax, 0.8)
        XCTAssertEqual(merged.minCapturedFrames, 12)

        XCTAssertThrowsError(try base.merged(withJSON: Data(#"{"spanMax": "wide"}"#.utf8)))
        XCTAssertThrowsError(try base.merged(withJSON: Data(#"{"minCapturedFrames": 1.5}"#.utf8)))

        // Every key round-trips and the defaults are the report's numbers.
        let data = try JSONEncoder().encode(CalibrationTuning.defaults)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object.count, CalibrationTuning.CodingKeys.allCases.count)
        XCTAssertEqual(try JSONDecoder().decode(CalibrationTuning.self, from: data), .defaults)
        let d = CalibrationTuning.defaults
        XCTAssertEqual(d.rollEnterDeg, 3)
        XCTAssertEqual(d.rollExitDeg, 5)
        XCTAssertEqual(d.tiltBackMinDeg, -5)
        XCTAssertEqual(d.tiltBackMaxDeg, 20)
        XCTAssertEqual(d.coreMinVisibility, 0.6)
        XCTAssertEqual(d.footMinVisibility, 0.5)
        XCTAssertEqual(d.relaxAfterS, 15)
        XCTAssertEqual(d.dimLumaMax, 0.22)
        XCTAssertEqual(d.tPoseMinScore, 0.55)
        XCTAssertEqual(d.dropoutToleranceS, 0.35)
        XCTAssertEqual(d.minCapturedFrames, 15)
        XCTAssertEqual(d.spanMinFloor, 0.22)
    }

    // MARK: - Cues and telemetry

    func testEveryCueHasSpokenText() {
        for cue in CalibrationCue.allCases {
            if cue == .none {
                XCTAssertEqual(cue.spokenText, "")
            } else {
                XCTAssertFalse(cue.spokenText.isEmpty, "\(cue)")
            }
        }
        XCTAssertEqual(Set(CalibrationCue.allCases.map(\.spokenText)).count, CalibrationCue.allCases.count)
        XCTAssertEqual(CalibrationStep.allCases.map(\.rawValue), [0, 1, 2, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13])
    }

    func testTelemetryIsFlatJSON() throws {
        var (g, t) = tposeGate()
        g.update(light: CalibrationLightSample(meanLuma: 0.3, torsoLuma: 0.3, borderLuma: 0.4, iso: 200,
                                               maxISO: 2000, exposureSeconds: 0.02, exposureLocked: true))
        g.update(motion: motion(2, tiltBack: 0.5))
        feed(&g, from: t, seconds: 0.3, body: { _ in Body(tpose: true) })
        let tel = g.telemetry()
        XCTAssertEqual(tel.step, "tpose")
        XCTAssertEqual(tel.stepIndex, 4)
        XCTAssertEqual(tel.cue, "holdStill")
        let data = try JSONEncoder().encode(tel)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for (key, value) in object {
            XCTAssertFalse(value is [String: Any] || value is [Any], "\(key) is nested")
        }
        for key in ["step", "cue", "relaxed", "progress", "rollDeg", "tiltBackDeg", "gravityDeltaG", "rollOK",
                    "span", "hipCenterX", "spanOK", "framingOK", "meanLuma", "isoRatio", "lightOK",
                    "tPoseScore", "tPoseSY", "bodyMotion", "tPoseOK", "bodyStillOK", "capturedFrameCount"] {
            XCTAssertNotNil(object[key], key)
        }
        XCTAssertEqual(try JSONDecoder().decode(CalibrationTelemetry.self, from: data), tel)
    }
}
