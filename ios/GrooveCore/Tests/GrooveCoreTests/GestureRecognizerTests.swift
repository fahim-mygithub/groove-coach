import XCTest
@testable import GrooveCore

final class GestureRecognizerTests: XCTestCase {

    private let dt = 1.0 / 30.0

    private func pt(_ x: Double, _ y: Double, _ c: Double = 1.0) -> GesturePoint {
        GesturePoint(x: x, y: y, confidence: c)
    }

    /// Runs `seconds` worth of 30 fps samples built by `make(t)` and collects fired legacy commands.
    private func run(
        _ rec: inout GestureRecognizer,
        seconds: Double,
        make: (Double) -> GestureSample
    ) -> [GestureCommand] {
        var out: [GestureCommand] = []
        let n = Int((seconds / dt).rounded())
        for i in 0...n {
            if let c = rec.process(make(Double(i) * dt)) { out.append(c) }
        }
        return out
    }

    /// Runs `seconds` worth of 30 fps samples starting at `startTime` and collects full `GestureEvent`s.
    private func runEvents(
        _ rec: inout GestureRecognizer,
        startTime: Double = 0.0,
        seconds: Double,
        make: (Double) -> GestureSample
    ) -> [GestureEvent] {
        var out: [GestureEvent] = []
        let n = Int((seconds / dt).rounded())
        for i in 0...n {
            let t = startTime + Double(i) * dt
            if let e = rec.processEvent(make(t)) { out.append(e) }
        }
        return out
    }

    // MARK: - Swipe (v1 baseline)

    private func swipeX(_ t: Double, direction: Double) -> Double {
        // 1 s still, then a 0.3 s straight sweep of 0.5, then still.
        let p = min(max((t - 1.0) / 0.3, 0), 1)
        return 0.5 - direction * 0.25 + direction * 0.5 * p
    }

    func testSwipeRightFiresOnce() {
        var rec = GestureRecognizer()
        let out = run(&rec, seconds: 3) {
            GestureSample(time: $0, rightWrist: self.pt(self.swipeX($0, direction: 1), 0.5))
        }
        XCTAssertEqual(out, [.swipeRight])
    }

    func testSwipeLeftFiresOnce() {
        var rec = GestureRecognizer()
        let out = run(&rec, seconds: 3) {
            GestureSample(time: $0, rightWrist: self.pt(self.swipeX($0, direction: -1), 0.5))
        }
        XCTAssertEqual(out, [.swipeLeft])
    }

    func testLowConfidenceSwipeIgnored() {
        var rec = GestureRecognizer()
        let out = run(&rec, seconds: 3) {
            GestureSample(time: $0, rightWrist: self.pt(self.swipeX($0, direction: 1), 0.5, 0.2))
        }
        XCTAssertTrue(out.isEmpty)
    }

    func testShortSwipeIgnored() {
        var rec = GestureRecognizer()
        let out = run(&rec, seconds: 3) { t in
            let p = min(max((t - 1.0) / 0.3, 0), 1)
            return GestureSample(time: t, rightWrist: self.pt(0.5 + 0.15 * p, 0.5))
        }
        XCTAssertTrue(out.isEmpty)
    }

    // MARK: - Clap (v1 baseline)

    private func clapGap(_ t: Double, start: Double = 1.0) -> Double {
        // Apart (0.4) until `start`, close to touching in 0.15 s, separate again in 0.15 s.
        if t < start { return 0.4 }
        if t < start + 0.15 { return 0.4 - 0.4 * (t - start) / 0.15 }
        if t < start + 0.30 { return 0.4 * (t - (start + 0.15)) / 0.15 }
        return 0.4
    }

    func testClapTogglesPauseOnce() {
        var rec = GestureRecognizer()
        let out = run(&rec, seconds: 3) { t in
            let gap = self.clapGap(t)
            return GestureSample(
                time: t,
                leftWrist: self.pt(0.5 - gap / 2, 0.5),
                rightWrist: self.pt(0.5 + gap / 2, 0.5)
            )
        }
        XCTAssertEqual(out, [.togglePause])
    }

    func testHandsMeetingAndStayingTogetherDoesNotClap() {
        var rec = GestureRecognizer()
        let out = run(&rec, seconds: 3) { t in
            let gap = t < 1.0 ? 0.4 : 0.02
            return GestureSample(
                time: t,
                leftWrist: self.pt(0.5 - gap / 2, 0.5),
                rightWrist: self.pt(0.5 + gap / 2, 0.5)
            )
        }
        XCTAssertTrue(out.isEmpty)
    }

    // MARK: - Hands raised (v1 baseline)

    private func raisedSample(_ t: Double, raisedFor: Double) -> GestureSample {
        let up = t >= 0.5 && t < 0.5 + raisedFor
        let y = up ? 0.9 : 0.5
        return GestureSample(time: t, leftWrist: pt(0.4, y), rightWrist: pt(0.6, y), headY: 0.75)
    }

    func testHandsRaisedHeldRestartsDrillOnce() {
        var rec = GestureRecognizer()
        let out = run(&rec, seconds: 4) { self.raisedSample($0, raisedFor: 2.5) }
        XCTAssertEqual(out, [.restartDrill])
    }

    func testHandsRaisedBrieflyDoesNothing() {
        var rec = GestureRecognizer()
        let out = run(&rec, seconds: 4) { self.raisedSample($0, raisedFor: 0.6) }
        XCTAssertTrue(out.isEmpty)
    }

    func testCooldownSuppressesRepeatClap() {
        var rec = GestureRecognizer()
        // Claps every 0.5 s in `.betweenTakes`: the 1 s cooldown must drop every other one.
        let out = run(&rec, seconds: 2.4) { t in
            let phase = t.truncatingRemainder(dividingBy: 0.5)
            let gap: Double
            if phase < 0.1 {
                gap = 0.4 * (1 - phase / 0.1)
            } else if phase < 0.2 {
                gap = 0.4 * (phase - 0.1) / 0.1
            } else {
                gap = 0.4
            }
            return GestureSample(
                time: t,
                leftWrist: self.pt(0.5 - gap / 2, 0.5),
                rightWrist: self.pt(0.5 + gap / 2, 0.5)
            )
        }
        XCTAssertFalse(out.isEmpty)
        XCTAssertLessThanOrEqual(out.count, 3)
        XCTAssertEqual(out.first, .togglePause)
    }

    // MARK: - Must NOT trigger during dancing (v1 baseline)

    func testDanceMotionTriggersNothing() {
        var rec = GestureRecognizer()
        let out = run(&rec, seconds: 20) { t in
            let w = 2.0 * Double.pi * 2.0
            let lx = 0.3 + 0.1 * sin(w * t)
            let rx = 0.7 + 0.1 * sin(w * t + 1.3)
            let ly = 0.55 + 0.25 * sin(w * t * 0.5)
            let ry = 0.55 + 0.25 * sin(w * t * 0.5 + 0.7)
            return GestureSample(
                time: t,
                leftWrist: self.pt(lx, ly),
                rightWrist: self.pt(rx, ry),
                headY: 0.7
            )
        }
        XCTAssertTrue(out.isEmpty, "fired \(out)")
    }

    func testContinuousBigArmSwingTriggersNothing() {
        var rec = GestureRecognizer()
        let out = run(&rec, seconds: 15) { t in
            GestureSample(
                time: t,
                rightWrist: self.pt(0.5 + 0.3 * sin(2.0 * Double.pi * 1.5 * t), 0.5)
            )
        }
        XCTAssertTrue(out.isEmpty, "fired \(out)")
    }

    func testSlowDriftTriggersNothing() {
        var rec = GestureRecognizer()
        let out = run(&rec, seconds: 10) { t in
            GestureSample(
                time: t,
                leftWrist: self.pt(0.3 + 0.03 * t, 0.5),
                rightWrist: self.pt(0.7 - 0.03 * t, 0.5),
                headY: 0.75
            )
        }
        XCTAssertTrue(out.isEmpty)
    }

    // MARK: - v2: MediaPipe Y-Flip & Hold Progress

    func testMediaPipeYFlipFixesRaisedHands() {
        // 1. Standing relaxed in MediaPipe y-down space: nose at y=0.25 (near top), wrists hanging down at y=0.55.
        // Without flipping (the v1 bug), wrist.y=0.55 > headY=0.25+0.05 falsely looked "above head".
        // With `fromMediaPipeNormalized`, wrist.y becomes 0.45 < headY=0.75, so standing relaxed never fires.
        var rec = GestureRecognizer()
        let relaxedFired = run(&rec, seconds: 2.5) { t in
            GestureSample.fromMediaPipeNormalized(
                time: t,
                leftWrist: self.pt(0.58, 0.55),
                rightWrist: self.pt(0.42, 0.55),
                headY: 0.25
            )
        }
        XCTAssertTrue(relaxedFired.isEmpty, "Standing with relaxed arms in MediaPipe y-down must not fire")
        XCTAssertEqual(rec.holdProgress, 0.0, accuracy: 1e-6)

        // 2. Raising both hands overhead in MediaPipe y-down space: wrists at y=0.10, nose at y=0.25
        // -> flipped wrist.y=0.90 > headY=0.75 + 0.05.
        rec.reset()
        var progressSamples: [Double] = []
        var overheadFired: [GestureCommand] = []
        let totalSteps = Int((2.0 / dt).rounded())
        for i in 0...totalSteps {
            let t = Double(i) * dt
            let mpWristY = (t >= 0.3 && t <= 1.6) ? 0.10 : 0.55
            let named: [String: CalibrationLandmark] = [
                "nose": CalibrationLandmark(x: 0.50, y: 0.25, visibility: 0.99),
                "leftWrist": CalibrationLandmark(x: 0.58, y: mpWristY, visibility: 0.95),
                "rightWrist": CalibrationLandmark(x: 0.42, y: mpWristY, visibility: 0.95)
            ]
            let pose = CalibrationPoseSample(timestamp: t, named: named)
            let sample = GestureSample.fromMediaPipeNormalized(
                time: t,
                landmarks: pose.landmarks,
                minConfidence: 0.5,
                mirrorX: true
            )
            if t == 0.0 {
                XCTAssertEqual(sample.leftWrist?.x ?? -1, 0.42, accuracy: 1e-6)
                XCTAssertEqual(sample.rightWrist?.x ?? -1, 0.58, accuracy: 1e-6)
                XCTAssertEqual(sample.leftWrist?.y ?? -1, 0.45, accuracy: 1e-6)
                XCTAssertEqual(sample.headY ?? -1, 0.75, accuracy: 1e-6)
            }
            if let cmd = rec.process(sample) {
                overheadFired.append(cmd)
            }
            progressSamples.append(rec.holdProgress)
        }
        XCTAssertEqual(overheadFired, [.restartDrill])
        let maxProgress = progressSamples.max() ?? 0.0
        XCTAssertGreaterThan(maxProgress, 0.85, "holdProgress must ramp toward 1.0 before firing")
        XCTAssertLessThanOrEqual(maxProgress, 1.0)
        XCTAssertEqual(rec.holdProgress, 0.0, accuracy: 1e-6, "holdProgress resets to 0 after release/fire")
    }

    // MARK: - v2: Lower-Hands 0.25 s Re-Arm Latch Across Phase Transitions

    func testStartHoldRequiresLoweringHandsBeforeCountInCancel() {
        var rec = GestureRecognizer(mode: .betweenTakes)
        var router = GestureRouter(host: .lesson, phase: .idle)
        var routedCommands: [CoachingCommand] = []
        var t = 0.0

        func step(seconds: Double, leftY: Double, rightY: Double, headY: Double = 0.75) {
            let n = Int((seconds / dt).rounded())
            for _ in 0..<n {
                t += dt
                let sample = GestureSample(
                    time: t,
                    leftWrist: pt(0.4, leftY),
                    rightWrist: pt(0.6, rightY),
                    headY: headY,
                    bodyMotion: 0.004
                )
                if let out = router.process(sample, recognizer: &rec) {
                    routedCommands.append(out.command)
                    if out.command == .startTake && router.phase == .idle {
                        // Immediate app transition `.idle` -> `.countIn` while hands are still overhead!
                        router.transition(to: .countIn, at: t, recognizer: &rec)
                    }
                }
            }
        }

        // 1. Hold hands up for 1.05 s in `.idle` -> fires `.startTake` and transitions into `.countIn`.
        step(seconds: 1.05, leftY: 0.90, rightY: 0.90)
        XCTAssertEqual(routedCommands, [.startTake])
        XCTAssertEqual(router.phase, .countIn)
        XCTAssertEqual(rec.mode, .countIn)
        XCTAssertTrue(rec.isHoldLatched)

        // 2. Keep hands raised overhead continuously for 2.2 s inside `.countIn` (well past 1.2 s countInHold):
        // must NOT self-cancel the take!
        step(seconds: 2.20, leftY: 0.90, rightY: 0.90)
        XCTAssertEqual(routedCommands, [.startTake], "Still-raised hands after Start must never cancel countIn")
        XCTAssertEqual(rec.holdProgress, 0.0, accuracy: 1e-6)
        XCTAssertTrue(rec.isHoldLatched)

        // 3. Lower only ONE hand below headY for 0.40 s -> must remain latched.
        step(seconds: 0.40, leftY: 0.55, rightY: 0.85)
        XCTAssertTrue(rec.isHoldLatched)

        // 4. Lower BOTH hands below headY for only 0.15 s (< 0.25 s) then raise again for 1.5 s -> still latched!
        step(seconds: 0.15, leftY: 0.55, rightY: 0.55)
        XCTAssertTrue(rec.isHoldLatched)
        step(seconds: 1.50, leftY: 0.90, rightY: 0.90)
        XCTAssertEqual(routedCommands, [.startTake], "Lowering hands < 0.25 s must not re-arm countIn cancel")

        // 5. Lower BOTH hands below headY continuously for >= 0.25 s (0.30 s) -> re-arms!
        step(seconds: 0.30, leftY: 0.55, rightY: 0.55)
        XCTAssertFalse(rec.isHoldLatched, "Lowering both hands below headY for >= 0.25 s must re-arm")

        // 6. Raise both hands stationary for 1.30 s (>= 1.2 s countInHold) -> cancels/pauses countIn!
        step(seconds: 1.30, leftY: 0.90, rightY: 0.90)
        XCTAssertEqual(routedCommands, [.startTake, .pauseTake])
    }

    // MARK: - v2: Count-In Disables Single Claps, Double-Claps, and Swipes

    func testCountInDisablesClapsAndDoubleClap() {
        var rec = GestureRecognizer(mode: .countIn)
        // Simulate 4-beat count-in at 120 BPM (claps every 0.5 s -> < 1.8 s apart) followed by a horizontal swipe.
        let claps = runEvents(&rec, seconds: 2.5) { t in
            let phase = t.truncatingRemainder(dividingBy: 0.5)
            let gap: Double
            if phase < 0.12 {
                gap = 0.42 * (1.0 - phase / 0.12)
            } else if phase < 0.24 {
                gap = 0.42 * (phase - 0.12) / 0.12
            } else {
                gap = 0.42
            }
            return GestureSample(
                time: t,
                leftWrist: self.pt(0.5 - gap / 2, 0.55),
                rightWrist: self.pt(0.5 + gap / 2, 0.55),
                headY: 0.75
            )
        }
        XCTAssertTrue(claps.isEmpty, "On-beat claps in .countIn must never fire togglePause or doubleClap: \(claps)")

        let swipes = runEvents(&rec, startTime: 2.6, seconds: 2.5) { t in
            let localT = t - 2.6
            return GestureSample(
                time: t,
                rightWrist: self.pt(self.swipeX(localT, direction: 1), 0.55),
                headY: 0.75
            )
        }
        XCTAssertTrue(swipes.isEmpty, "Swipes in .countIn must be disabled: \(swipes)")
    }

    // MARK: - v2: Calibrating Double-Clap Skip & Zero False Triggers Across All 9 Poses

    func testCalibrationDoubleClapSkipsAndPosesNeverTrigger() {
        var rec = GestureRecognizer(mode: .calibrating)
        var router = GestureRouter(host: .lesson, phase: .calibrating)

        // 1. Walk through all 9 calibration poses (10 holds: rest, tpose, overhead, asymLR,
        //    armsForward, plie, turned45, stepLeft, stepRight, kneeLift) in MediaPipe y-down coordinates.
        //    Includes fast horizontal arm extension into T-pose, > 1.2 s overhead hold, and lateral steps.
        struct PoseSpec {
            let lx: Double
            let ly: Double
            let rx: Double
            let ry: Double
            let noseY: Double
            let duration: Double
        }
        let ninePoses: [PoseSpec] = [
            PoseSpec(lx: 0.58, ly: 0.56, rx: 0.42, ry: 0.56, noseY: 0.25, duration: 0.8), // Pose 1: .rest
            PoseSpec(lx: 0.84, ly: 0.33, rx: 0.16, ry: 0.33, noseY: 0.25, duration: 1.2), // Pose 2: .tpose
            PoseSpec(lx: 0.58, ly: 0.09, rx: 0.42, ry: 0.09, noseY: 0.25, duration: 1.4), // Pose 3: .overhead
            PoseSpec(lx: 0.58, ly: 0.10, rx: 0.18, ry: 0.33, noseY: 0.25, duration: 0.9), // Pose 4: .asymLR
            PoseSpec(lx: 0.56, ly: 0.33, rx: 0.44, ry: 0.33, noseY: 0.25, duration: 0.9), // Pose 5: .armsForward
            PoseSpec(lx: 0.78, ly: 0.39, rx: 0.22, ry: 0.39, noseY: 0.31, duration: 1.0), // Pose 6: .plie
            PoseSpec(lx: 0.70, ly: 0.34, rx: 0.30, ry: 0.34, noseY: 0.25, duration: 0.9), // Pose 7: .turned45
            PoseSpec(lx: 0.72, ly: 0.54, rx: 0.56, ry: 0.54, noseY: 0.25, duration: 0.7), // Pose 8a: .stepLeft
            PoseSpec(lx: 0.44, ly: 0.54, rx: 0.28, ry: 0.54, noseY: 0.25, duration: 0.7), // Pose 8b: .stepRight
            PoseSpec(lx: 0.59, ly: 0.48, rx: 0.41, ry: 0.48, noseY: 0.25, duration: 0.8)  // Pose 9: .kneeLift
        ]

        var t = 0.0
        var prevLX = ninePoses[0].lx
        var prevLY = ninePoses[0].ly
        var prevRX = ninePoses[0].rx
        var prevRY = ninePoses[0].ry
        var poseEvents: [GestureEvent] = []

        for spec in ninePoses {
            let steps = Int((spec.duration / dt).rounded())
            for k in 0..<steps {
                t += dt
                // Smooth 0.20 s transition into each pose followed by steady hold.
                let alpha = min(1.0, Double(k) * dt / 0.20)
                let lx = prevLX + (spec.lx - prevLX) * alpha
                let ly = prevLY + (spec.ly - prevLY) * alpha
                let rx = prevRX + (spec.rx - prevRX) * alpha
                let ry = prevRY + (spec.ry - prevRY) * alpha
                let sample = GestureSample.fromMediaPipeNormalized(
                    time: t,
                    leftWrist: pt(lx, ly),
                    rightWrist: pt(rx, ry),
                    headY: spec.noseY
                )
                if let e = rec.processEvent(sample) {
                    poseEvents.append(e)
                }
                XCTAssertEqual(rec.holdProgress, 0.0, accuracy: 1e-6)
            }
            prevLX = spec.lx
            prevLY = spec.ly
            prevRX = spec.rx
            prevRY = spec.ry
        }
        XCTAssertTrue(poseEvents.isEmpty, "None of the 9 calibration poses may trigger a gesture: \(poseEvents)")

        // 2. Single clap in `.calibrating` -> repeats spoken cue; second clap > 1.8 s later -> repeats again (not skip).
        var singleClapRouted: [CoachingCommand] = []
        let nSingle = Int((3.5 / dt).rounded())
        let baseSingle = t + 0.1
        for i in 0...nSingle {
            let now = baseSingle + Double(i) * dt
            let local = now - baseSingle
            // Clap at 0.3 s and another at 2.6 s (2.3 s apart > 1.8 s doubleClapWindow).
            let gap = min(clapGap(local, start: 0.3), clapGap(local, start: 2.6))
            let sample = GestureSample(
                time: now,
                leftWrist: pt(0.5 - gap / 2, 0.5),
                rightWrist: pt(0.5 + gap / 2, 0.5),
                headY: 0.75
            )
            if let routed = router.process(sample, recognizer: &rec) {
                singleClapRouted.append(routed.command)
            }
            t = now
        }
        XCTAssertEqual(singleClapRouted, [.repeatCalibrationCue, .repeatCalibrationCue])

        // 3. Double clap within <= 1.8 s (0.55 s apart, even inside normal 1.0 s cooldown!) -> skips calibration!
        rec.resetPreservingHoldLatch()
        var doubleClapEvents: [GestureEvent] = []
        var doubleClapCommands: [CoachingCommand] = []
        let baseDouble = t + 0.5
        let nDouble = Int((2.0 / dt).rounded())
        for i in 0...nDouble {
            let now = baseDouble + Double(i) * dt
            let local = now - baseDouble
            let gap = min(clapGap(local, start: 0.30), clapGap(local, start: 0.85))
            let sample = GestureSample(
                time: now,
                leftWrist: pt(0.5 - gap / 2, 0.5),
                rightWrist: pt(0.5 + gap / 2, 0.5),
                headY: 0.75
            )
            if let routed = router.process(sample, recognizer: &rec) {
                doubleClapEvents.append(routed.event)
                doubleClapCommands.append(routed.command)
            }
        }
        XCTAssertEqual(doubleClapEvents, [.togglePause, .doubleClap])
        XCTAssertEqual(doubleClapCommands, [.repeatCalibrationCue, .skipCalibration])
    }

    // MARK: - v2: Recording 2.0 s Stationary Hold vs Choreography

    func testRecordingStationaryHoldIgnoresChoreography() {
        var rec = GestureRecognizer(mode: .recording)
        var router = GestureRouter(host: .lesson, phase: .recording)

        // 1. Segment B ("Peek-a-Boo to Lateral Sweep"): quiet wind-up + > 35% horizontal sweep -> 0 triggers.
        let sweepEvents = runEvents(&rec, startTime: 0.0, seconds: 2.5) { t in
            GestureSample(
                time: t,
                leftWrist: self.pt(0.30, 0.55),
                rightWrist: self.pt(self.swipeX(t, direction: 1), 0.55),
                headY: 0.75,
                bodyMotion: 0.035
            )
        }
        XCTAssertTrue(sweepEvents.isEmpty, "Lateral sweep choreography must not fire in .recording")

        // 2. Namaste / wrist clasp & rapid double-claps during dance -> 0 triggers.
        let claspEvents = runEvents(&rec, startTime: 2.6, seconds: 2.5) { t in
            let local = t - 2.6
            let gap = min(self.clapGap(local, start: 0.3), self.clapGap(local, start: 0.9))
            return GestureSample(
                time: t,
                leftWrist: self.pt(0.5 - gap / 2, 0.55),
                rightWrist: self.pt(0.5 + gap / 2, 0.55),
                headY: 0.75,
                bodyMotion: 0.015
            )
        }
        XCTAssertTrue(claspEvents.isEmpty, "Clasps/claps must not fire in .recording")

        // 3. Segment D ("Crown Lotus"): stationary overhead hold for 0.90 s and 1.60 s (< 2.0 s) -> 0 triggers.
        let crownLotusEvents = runEvents(&rec, startTime: 5.2, seconds: 2.5) { t in
            let local = t - 5.2
            let up = local >= 0.3 && local < 1.9 // 1.60 s < 2.0 s
            let y = up ? 0.90 : 0.50
            return GestureSample(
                time: t,
                leftWrist: self.pt(0.45, y),
                rightWrist: self.pt(0.55, y),
                headY: 0.75,
                bodyMotion: 0.006
            )
        }
        XCTAssertTrue(crownLotusEvents.isEmpty, "Crown Lotus (< 2.0 s) must not trigger emergency pause")

        // 4. Overhead arms for 2.8 s while torso/hips are dancing (`bodyMotion = 0.032 > 0.020`) -> 0 triggers.
        let movingBodyEvents = runEvents(&rec, startTime: 7.8, seconds: 3.2) { t in
            let local = t - 7.8
            let up = local >= 0.2 && local < 3.0
            let y = up ? 0.90 : 0.50
            return GestureSample(
                time: t,
                leftWrist: self.pt(0.42, y),
                rightWrist: self.pt(0.58, y),
                headY: 0.75,
                bodyMotion: 0.032
            )
        }
        XCTAssertTrue(movingBodyEvents.isEmpty, "Non-stationary bodyMotion > 0.020 must never pause recording")

        // 5. Overhead arms for 2.8 s with `bodyMotion == nil` while wrists wave overhead at 2 Hz -> 0 triggers.
        let wavingOverheadEvents = runEvents(&rec, startTime: 11.1, seconds: 3.2) { t in
            let local = t - 11.1
            let up = local >= 0.2 && local < 3.0
            let wave = 0.08 * sin(2.0 * Double.pi * 2.0 * local)
            let y = up ? (0.88 + wave) : 0.50
            return GestureSample(
                time: t,
                leftWrist: self.pt(0.40 + wave, y),
                rightWrist: self.pt(0.60 - wave, y),
                headY: 0.75,
                bodyMotion: nil
            )
        }
        XCTAssertTrue(wavingOverheadEvents.isEmpty, "Waving wrists overhead must fail stillness gate")

        // 6. Deliberate emergency pause: lower hands >= 0.25 s, then hold stationary (`bodyMotion <= 0.020`) for >= 2.0 s.
        var emergencyRouted: [CoachingCommand] = []
        let startHold = 14.5
        let steps = Int((2.8 / dt).rounded())
        for i in 0...steps {
            let t = startHold + Double(i) * dt
            let local = t - startHold
            let y = local >= 0.4 ? 0.90 : 0.50 // 0.4 s down, then 2.4 s stationary overhead
            let sample = GestureSample(
                time: t,
                leftWrist: pt(0.42, y),
                rightWrist: pt(0.58, y),
                headY: 0.75,
                bodyMotion: 0.008
            )
            if let out = router.process(sample, recognizer: &rec) {
                emergencyRouted.append(out.command)
            }
        }
        XCTAssertEqual(emergencyRouted, [.pauseTake])
    }

    // MARK: - v2: Disabled Mode & Full GestureRouter Phase Matrix

    func testDisabledModeSuppressesAllGestures() {
        var rec = GestureRecognizer(mode: .disabled)
        let clapEvents = runEvents(&rec, startTime: 0, seconds: 2.0) { t in
            let gap = min(self.clapGap(t, start: 0.2), self.clapGap(t, start: 0.8))
            return GestureSample(
                time: t,
                leftWrist: self.pt(0.5 - gap / 2, 0.5),
                rightWrist: self.pt(0.5 + gap / 2, 0.5),
                headY: 0.75
            )
        }
        let holdEvents = runEvents(&rec, startTime: 2.1, seconds: 2.5) { t in
            GestureSample(
                time: t,
                leftWrist: self.pt(0.4, 0.92),
                rightWrist: self.pt(0.6, 0.92),
                headY: 0.75,
                bodyMotion: 0.0
            )
        }
        XCTAssertTrue(clapEvents.isEmpty)
        XCTAssertTrue(holdEvents.isEmpty)
        XCTAssertEqual(rec.holdProgress, 0.0, accuracy: 1e-6)
    }

    func testGestureRouterPhaseMatrixAndResultsGraceWindow() {
        // 1. `.idle` Lesson vs Practice
        XCTAssertEqual(GestureRouter.route(.togglePause, phase: .idle, host: .lesson), .togglePreviewPlayPause)
        XCTAssertEqual(GestureRouter.route(.togglePause, phase: .idle, host: .practice), .startTake)
        XCTAssertNil(GestureRouter.route(.doubleClap, phase: .idle, host: .lesson))
        XCTAssertEqual(GestureRouter.route(.restartDrill, phase: .idle, host: .lesson), .startTake)
        XCTAssertEqual(GestureRouter.route(.swipeLeft, phase: .idle, host: .lesson), .restartPreview)
        XCTAssertEqual(GestureRouter.route(.swipeLeft, phase: .idle, host: .practice), .startTake)
        XCTAssertNil(GestureRouter.route(.swipeRight, phase: .idle, host: .lesson, nextUnlocked: false))
        XCTAssertEqual(GestureRouter.route(.swipeRight, phase: .idle, host: .lesson, nextUnlocked: true), .nextItem)
        XCTAssertEqual(GestureRouter.route(.swipeRight, phase: .idle, host: .practice, nextUnlocked: false), .nextItem)

        // 2. `.calibrating`
        XCTAssertEqual(GestureRouter.route(.togglePause, phase: .calibrating), .repeatCalibrationCue)
        XCTAssertEqual(GestureRouter.route(.doubleClap, phase: .calibrating), .skipCalibration)
        XCTAssertNil(GestureRouter.route(.restartDrill, phase: .calibrating))
        XCTAssertNil(GestureRouter.route(.swipeLeft, phase: .calibrating))
        XCTAssertNil(GestureRouter.route(.swipeRight, phase: .calibrating))

        // 3. `.countIn`, `.recording`, `.analyzing`, `.clapSync`
        for phase in [CoachingPhase.countIn, .recording] {
            XCTAssertEqual(GestureRouter.route(.restartDrill, phase: phase), .pauseTake)
            XCTAssertNil(GestureRouter.route(.togglePause, phase: phase))
            XCTAssertNil(GestureRouter.route(.doubleClap, phase: phase))
            XCTAssertNil(GestureRouter.route(.swipeLeft, phase: phase))
            XCTAssertNil(GestureRouter.route(.swipeRight, phase: phase))
        }
        for phase in [CoachingPhase.analyzing, .clapSync] {
            for event in GestureEvent.allCases {
                XCTAssertNil(GestureRouter.route(event, phase: phase))
            }
        }

        // 4. `.results` (passed vs failed, unlocked vs locked) + 1.0 s post-take grace cooldown
        XCTAssertEqual(
            GestureRouter.route(.togglePause, phase: .results, host: .lesson, passed: true, nextUnlocked: true),
            .nextItem
        )
        XCTAssertEqual(
            GestureRouter.route(.togglePause, phase: .results, host: .lesson, passed: false, nextUnlocked: true),
            .startTake
        )
        XCTAssertEqual(
            GestureRouter.route(.togglePause, phase: .results, host: .lesson, passed: true, nextUnlocked: false),
            .startTake
        )
        XCTAssertEqual(
            GestureRouter.route(.swipeRight, phase: .results, host: .lesson, passed: false, nextUnlocked: false),
            .returnToReview
        )
        XCTAssertEqual(
            GestureRouter.route(.swipeRight, phase: .results, host: .lesson, passed: false, nextUnlocked: true),
            .nextItem
        )
        XCTAssertEqual(GestureRouter.route(.swipeLeft, phase: .results, host: .lesson), .startTake)
        XCTAssertEqual(GestureRouter.route(.restartDrill, phase: .results, host: .lesson), .startTake)

        var rec = GestureRecognizer()
        var router = GestureRouter(host: .lesson, phase: .analyzing, postTakeGraceDuration: 1.0)
        router.transition(to: .results, at: 10.0, recognizer: &rec)
        XCTAssertTrue(router.isInResultsGraceWindow(at: 10.0))
        XCTAssertTrue(router.isInResultsGraceWindow(at: 10.95))
        XCTAssertNil(router.route(.togglePause, at: 10.5, passed: true, nextUnlocked: true))
        XCTAssertFalse(router.isInResultsGraceWindow(at: 11.0))
        XCTAssertEqual(router.route(.togglePause, at: 11.0, passed: true, nextUnlocked: true), .nextItem)

        // 5. `.paused`
        XCTAssertEqual(GestureRouter.route(.togglePause, phase: .paused, host: .lesson), .startTake)
        XCTAssertEqual(GestureRouter.route(.restartDrill, phase: .paused, host: .lesson), .startTake)
        XCTAssertEqual(GestureRouter.route(.swipeLeft, phase: .paused, host: .lesson), .returnToReview)
        XCTAssertNil(GestureRouter.route(.swipeRight, phase: .paused, host: .lesson, nextUnlocked: false))
        XCTAssertEqual(GestureRouter.route(.swipeRight, phase: .paused, host: .lesson, nextUnlocked: true), .nextItem)
    }
}
