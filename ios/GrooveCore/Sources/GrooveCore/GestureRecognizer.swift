import Foundation

/// Hands-free control gestures for Groove Coach (app-only; no Python parity).
/// Pure Swift over a timestamped stream of wrist positions, so it can be fed by
/// `VNDetectHumanHandPoseRequest` or body-pose wrists. Foundation only (Linux CI compatible).
///
/// Coordinates are normalised image coordinates with Vision's convention: x to the right,
/// y UP, both in 0...1. "Left"/"right" in swipe commands refer to the direction of travel
/// in image space (callers mirror for a selfie camera if needed).
///
/// Anti-false-positive design (dancing is continuous, gestures are deliberate):
/// - Swipe: needs a quiet wind-up (wrist nearly still) right before a fast, long, straight sweep.
///   Continuous dance arm motion never has the still wind-up.
/// - Clap: wrists must start well apart, meet quickly, then separate again.
/// - Hands raised: both wrists above the head for a sustained hold (default 1 s).
/// - Samples under the confidence floor count as "not seen" and reset the gesture state.
/// - A global cooldown stops one gesture from firing twice.
public enum GestureCommand: String, Sendable, Codable, Equatable {
    case swipeLeft
    case swipeRight
    case togglePause
    case restartDrill
}

public struct GesturePoint: Sendable, Codable, Equatable {
    public var x: Double
    public var y: Double
    public var confidence: Double

    public init(x: Double, y: Double, confidence: Double = 1.0) {
        self.x = x
        self.y = y
        self.confidence = confidence
    }
}

public struct GestureSample: Sendable, Codable, Equatable {
    public var time: Double
    public var leftWrist: GesturePoint?
    public var rightWrist: GesturePoint?
    /// Head (or nose/eye-line) height in the same y-up coordinates; needed for "hands raised".
    public var headY: Double?

    public init(time: Double, leftWrist: GesturePoint? = nil, rightWrist: GesturePoint? = nil, headY: Double? = nil) {
        self.time = time
        self.leftWrist = leftWrist
        self.rightWrist = rightWrist
        self.headY = headY
    }
}

public struct GestureConfig: Sendable, Equatable {
    /// Wrists below this confidence are treated as missing.
    public var confidenceFloor = 0.5
    /// Minimum seconds between any two emitted commands.
    public var cooldown = 1.0
    /// A gap between samples longer than this clears the tracks.
    public var maxGap = 0.25

    // Swipe
    /// Sweep must complete within this many seconds.
    public var swipeWindow = 0.5
    /// Minimum net horizontal travel (fraction of image width).
    public var swipeMinDistance = 0.35
    /// Net distance / path length must be at least this (straight sweep, not a wiggle).
    public var swipeMinStraightness = 0.9
    /// Maximum |dy| relative to |dx|.
    public var swipeMaxVerticalRatio = 0.5
    /// Seconds of stillness required before the sweep window.
    public var swipeQuietDuration = 0.3
    /// Maximum wrist extent (either axis) during the still wind-up.
    public var swipeQuietExtent = 0.08

    // Clap
    /// Wrists must have been at least this far apart shortly before meeting.
    public var clapApartDistance = 0.30
    /// Distance at or below which the wrists count as meeting.
    public var clapTouchDistance = 0.06
    /// Closing from apart to touch must take at most this long.
    public var clapCloseWindow = 0.35
    /// After meeting, wrists must separate beyond this distance...
    public var clapSeparateDistance = 0.15
    /// ...within this many seconds.
    public var clapSeparateWindow = 0.4

    // Hands raised
    /// Both wrists must exceed headY by this margin.
    public var raisedMargin = 0.05
    /// Seconds the pose must be held.
    public var raisedHold = 1.0

    public init() {}
}

public struct GestureRecognizer: Sendable {

    private struct TrackPoint {
        var t: Double
        var x: Double
        var y: Double
    }

    public let config: GestureConfig

    private var tracks: [[TrackPoint]] = [[], []]
    private var distances: [(t: Double, d: Double)] = []
    private var lastSampleTime: Double?
    private var lastFire: Double?
    private var clapMeetTime: Double?
    private var raisedStart: Double?
    private var raisedConsumed = false

    public init(config: GestureConfig = GestureConfig()) {
        self.config = config
    }

    public mutating func reset() {
        tracks = [[], []]
        distances = []
        lastSampleTime = nil
        clapMeetTime = nil
        raisedStart = nil
        raisedConsumed = false
    }

    /// Feed one sample (monotonically increasing time). Returns a command when a gesture completes.
    public mutating func process(_ sample: GestureSample) -> GestureCommand? {
        let t = sample.time
        let hands = [usable(sample.leftWrist), usable(sample.rightWrist)]

        if let last = lastSampleTime, t - last > config.maxGap { reset() }
        lastSampleTime = t

        for i in 0..<2 {
            if let p = hands[i] {
                tracks[i].append(TrackPoint(t: t, x: p.x, y: p.y))
                let cutoff = t - (config.swipeWindow + config.swipeQuietDuration + 0.1)
                tracks[i].removeAll { $0.t < cutoff }
            } else {
                tracks[i].removeAll()
            }
        }

        var candidate: GestureCommand?

        // Hands raised
        if let l = hands[0], let r = hands[1], let head = sample.headY,
           l.y > head + config.raisedMargin, r.y > head + config.raisedMargin {
            if raisedStart == nil { raisedStart = t }
            if !raisedConsumed, let start = raisedStart, t - start >= config.raisedHold {
                raisedConsumed = true
                candidate = .restartDrill
            }
        } else {
            raisedStart = nil
            raisedConsumed = false
        }

        // Clap
        if let l = hands[0], let r = hands[1] {
            let d = ((l.x - r.x) * (l.x - r.x) + (l.y - r.y) * (l.y - r.y)).squareRoot()
            distances.append((t: t, d: d))
            distances.removeAll { $0.t < t - 1.0 }
            if let meet = clapMeetTime {
                if d >= config.clapSeparateDistance {
                    clapMeetTime = nil
                    if candidate == nil { candidate = .togglePause }
                } else if t - meet > config.clapSeparateWindow {
                    clapMeetTime = nil
                }
            } else if d <= config.clapTouchDistance {
                let from = t - config.clapCloseWindow
                if distances.contains(where: { $0.t >= from && $0.d >= config.clapApartDistance }) {
                    clapMeetTime = t
                }
            }
        } else {
            distances.removeAll()
            clapMeetTime = nil
        }

        // Swipe
        if candidate == nil {
            for i in 0..<2 {
                if let c = swipe(track: tracks[i], now: t) {
                    candidate = c
                    break
                }
            }
        }

        guard let command = candidate else { return nil }
        if let last = lastFire, t - last < config.cooldown { return nil }
        lastFire = t
        // Consume motion history so the same movement cannot re-trigger after the cooldown.
        tracks = [[], []]
        distances = []
        clapMeetTime = nil
        return command
    }

    private func usable(_ p: GesturePoint?) -> GesturePoint? {
        guard let p = p, p.confidence >= config.confidenceFloor else { return nil }
        return p
    }

    private func swipe(track: [TrackPoint], now: Double) -> GestureCommand? {
        let windowStart = now - config.swipeWindow
        let sweep = track.filter { $0.t >= windowStart }
        guard let first = sweep.first, let last = sweep.last, sweep.count >= 3 else { return nil }

        let dx = last.x - first.x
        let dy = last.y - first.y
        guard abs(dx) >= config.swipeMinDistance else { return nil }
        guard abs(dy) <= config.swipeMaxVerticalRatio * abs(dx) else { return nil }

        var path = 0.0
        for k in 1..<sweep.count {
            let a = sweep[k - 1]
            let b = sweep[k]
            path += ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)).squareRoot()
        }
        guard path > 0, (dx * dx + dy * dy).squareRoot() / path >= config.swipeMinStraightness else { return nil }

        // Quiet wind-up immediately before the sweep window.
        let quietStart = windowStart - config.swipeQuietDuration
        let quiet = track.filter { $0.t >= quietStart && $0.t < windowStart }
        guard quiet.count >= 2, let qFirst = quiet.first, let qLast = quiet.last,
              qLast.t - qFirst.t >= config.swipeQuietDuration * 0.6 else { return nil }
        let xs = quiet.map { $0.x }
        let ys = quiet.map { $0.y }
        guard let xMin = xs.min(), let xMax = xs.max(), let yMin = ys.min(), let yMax = ys.max() else { return nil }
        guard xMax - xMin <= config.swipeQuietExtent, yMax - yMin <= config.swipeQuietExtent else { return nil }

        return dx > 0 ? .swipeRight : .swipeLeft
    }
}
