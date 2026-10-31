import XCTest
@testable import GrooveCore

final class GestureRecognizerTests: XCTestCase {

    private let dt = 1.0 / 30.0

    private func pt(_ x: Double, _ y: Double, _ c: Double = 1.0) -> GesturePoint {
        GesturePoint(x: x, y: y, confidence: c)
    }

    /// Runs `seconds` worth of 30 fps samples built by `make(t)` and collects fired commands.
    private func run(_ rec: inout GestureRecognizer, seconds: Double,
                     make: (Double) -> GestureSample) -> [GestureCommand] {
        var out: [GestureCommand] = []
        let n = Int(seconds / dt)
        for i in 0...n {
            if let c = rec.process(make(Double(i) * dt)) { out.append(c) }
        }
        return out
    }

    // MARK: - Swipe

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

    // MARK: - Clap

    private func clapGap(_ t: Double) -> Double {
        // Apart (0.4) until 1.0, close to touching in 0.15 s, separate again in 0.15 s.
        if t < 1.0 { return 0.4 }
        if t < 1.15 { return 0.4 - 0.4 * (t - 1.0) / 0.15 }
        if t < 1.3 { return 0.4 * (t - 1.15) / 0.15 }
        return 0.4
    }

    func testClapTogglesPauseOnce() {
        var rec = GestureRecognizer()
        let out = run(&rec, seconds: 3) { t in
            let gap = self.clapGap(t)
            return GestureSample(time: t, leftWrist: self.pt(0.5 - gap / 2, 0.5), rightWrist: self.pt(0.5 + gap / 2, 0.5))
        }
        XCTAssertEqual(out, [.togglePause])
    }

    func testHandsMeetingAndStayingTogetherDoesNotClap() {
        var rec = GestureRecognizer()
        let out = run(&rec, seconds: 3) { t in
            let gap = t < 1.0 ? 0.4 : 0.02
            return GestureSample(time: t, leftWrist: self.pt(0.5 - gap / 2, 0.5), rightWrist: self.pt(0.5 + gap / 2, 0.5))
        }
        XCTAssertTrue(out.isEmpty)
    }

    // MARK: - Hands raised

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
        // Claps every 0.5 s: the 1 s cooldown must drop every other one.
        let out = run(&rec, seconds: 2.4) { t in
            let phase = t.truncatingRemainder(dividingBy: 0.5)
            let gap = phase < 0.1 ? 0.4 * (1 - phase / 0.1) : (phase < 0.2 ? 0.4 * (phase - 0.1) / 0.1 : 0.4)
            return GestureSample(time: t, leftWrist: self.pt(0.5 - gap / 2, 0.5), rightWrist: self.pt(0.5 + gap / 2, 0.5))
        }
        XCTAssertFalse(out.isEmpty)
        XCTAssertLessThanOrEqual(out.count, 3)
        XCTAssertEqual(out.first, .togglePause)
    }

    // MARK: - Must NOT trigger during dancing

    func testDanceMotionTriggersNothing() {
        var rec = GestureRecognizer()
        // 20 s of continuous arm sway and pumps at ~2 Hz; hands stay apart, never held above head.
        let out = run(&rec, seconds: 20) { t in
            let w = 2.0 * Double.pi * 2.0
            let lx = 0.3 + 0.1 * sin(w * t)
            let rx = 0.7 + 0.1 * sin(w * t + 1.3)
            let ly = 0.55 + 0.25 * sin(w * t * 0.5)
            let ry = 0.55 + 0.25 * sin(w * t * 0.5 + 0.7)
            return GestureSample(time: t, leftWrist: self.pt(lx, ly), rightWrist: self.pt(rx, ry), headY: 0.7)
        }
        XCTAssertTrue(out.isEmpty, "fired \(out)")
    }

    func testContinuousBigArmSwingTriggersNothing() {
        var rec = GestureRecognizer()
        // One arm sweeping +-0.3 at 1.5 Hz: long straight half-swings, but no still wind-up.
        let out = run(&rec, seconds: 15) { t in
            GestureSample(time: t, rightWrist: self.pt(0.5 + 0.3 * sin(2.0 * Double.pi * 1.5 * t), 0.5))
        }
        XCTAssertTrue(out.isEmpty, "fired \(out)")
    }

    func testSlowDriftTriggersNothing() {
        var rec = GestureRecognizer()
        let out = run(&rec, seconds: 10) { t in
            GestureSample(time: t, leftWrist: self.pt(0.3 + 0.03 * t, 0.5), rightWrist: self.pt(0.7 - 0.03 * t, 0.5), headY: 0.75)
        }
        XCTAssertTrue(out.isEmpty)
    }
}
