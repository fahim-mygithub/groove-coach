import Foundation

/// Hands-free control gestures for Groove Coach (app-only; no Python parity).
/// Pure Swift over a timestamped stream of wrist and head positions from MediaPipe body/hand pose.
/// Foundation only (Linux CI compatible).
///
/// Coordinates in `GestureSample` use Vision-style normalised image space: `x` to the right,
/// `y` UP, both in `0...1`. Call `GestureSample.fromMediaPipeNormalized(...)` when feeding
/// MediaPipe normalised landmarks (`y` down) so `y = 1.0 - mpY` is flipped once.
/// "Left"/"right" in swipe commands refer to the direction of travel in `GestureSample`'s
/// `x` space (pass `mirrorX: true` when matching a horizontally mirrored preview).
///
/// Anti-false-positive design (dancing is continuous, gestures are deliberate):
/// - Mode gating (`GestureMode`): swipes are active only in `.betweenTakes`; claps are active
///   only in `.betweenTakes` (single clap) and `.calibrating` (single clap + `<= 1.8 s` double clap);
///   overhead holds are disabled in `.calibrating` and `.disabled`, require `1.2 s` stationary hold
///   in `.countIn`, and require `2.0 s` stationary hold (`bodyMotion <= 0.020`) in `.recording`.
/// - Lower-hands re-arm latch (`resetPreservingHoldLatch()`): after firing an overhead hold or
///   transitioning modes with hands above `headY`, both wrists must stay below `headY` continuously
///   for `0.25 s` before a new overhead hold can arm.
/// - Swipe: needs a quiet wind-up (wrist nearly still) right before a fast, long, straight sweep.
/// - Clap: wrists must start well apart, meet quickly, then separate again.
/// - Samples under the confidence floor count as "not seen" and reset transient tracks.

/// Legacy 4-case command enum preserved so existing exhaustive switches in `GrooveApp`
/// (`PracticeView.swift`) remain source-compatible across phased waves.
/// For full v2 routing (including `.doubleClap` during calibration), use `GestureEvent`
/// and `GestureRecognizer.processEvent(_:)` with `GestureRouter`.
public enum GestureCommand: String, Sendable, Codable, Equatable {
    case swipeLeft
    case swipeRight
    case togglePause
    case restartDrill
}

/// Full v2 recognized gesture event, adding `.doubleClap` (two claps within `<= 1.8 s` in `.calibrating`)
/// while bridging cleanly to and from `GestureCommand`.
public enum GestureEvent: String, Sendable, Codable, Equatable, CaseIterable {
    case swipeLeft
    case swipeRight
    case togglePause
    case doubleClap
    case restartDrill

    public init(_ command: GestureCommand) {
        switch command {
        case .swipeLeft: self = .swipeLeft
        case .swipeRight: self = .swipeRight
        case .togglePause: self = .togglePause
        case .restartDrill: self = .restartDrill
        }
    }

    /// Maps to the 4-case `GestureCommand` (`nil` only for `.doubleClap`).
    public var legacyCommand: GestureCommand? {
        switch self {
        case .swipeLeft: return .swipeLeft
        case .swipeRight: return .swipeRight
        case .togglePause: return .togglePause
        case .doubleClap: return nil
        case .restartDrill: return .restartDrill
        }
    }
}

/// Operating mode of `GestureRecognizer` across coaching phases (spec §5.2).
public enum GestureMode: String, Sendable, Codable, Equatable, CaseIterable {
    /// `.idle`, `.results`, `.paused`: single clap (`togglePause`), `1.0 s` overhead hold (`restartDrill`),
    /// and quiet-windup horizontal swipes (`swipeLeft`, `swipeRight`).
    case betweenTakes
    /// Calibration Poses 1–9: single clap (`togglePause` -> repeat cue) and `<= 1.8 s` `doubleClap` (-> skip);
    /// overhead holds and swipes are disabled so calibration poses never trigger gestures.
    case calibrating
    /// 4-beat count-in: claps, double-claps, and swipes are disabled; `1.2 s` stationary overhead hold
    /// cancels/pauses the take only after the lower-hands `0.25 s` re-arm gate.
    case countIn
    /// Active dance recording: claps, double-claps, and swipes are disabled; `2.0 s` stationary overhead hold
    /// (`bodyMotion <= 0.020`) emergency-pauses the take only after the lower-hands `0.25 s` re-arm gate.
    case recording
    /// Post-take `.analyzing` and 3-clap sync sheet: all gesture emissions suppressed.
    case disabled
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
    /// Head (or nose/eye-line) height in the same `y`-up coordinates; needed for "hands raised".
    public var headY: Double?
    /// Optional frame-to-frame normalised body motion (e.g. Ashrium shoulder/hip midpoint displacement
    /// divided by nose-to-foot span, matching `CalibrationGate.bodyMotion`). Used to verify stillness
    /// (`<= 0.020`) during stationary holds in `.countIn` and `.recording`.
    public var bodyMotion: Double?

    public init(
        time: Double,
        leftWrist: GesturePoint? = nil,
        rightWrist: GesturePoint? = nil,
        headY: Double? = nil,
        bodyMotion: Double? = nil
    ) {
        self.time = time
        self.leftWrist = leftWrist
        self.rightWrist = rightWrist
        self.headY = headY
        self.bodyMotion = bodyMotion
    }

    /// Converts MediaPipe normalised `y`-down (`0` = top, `1` = bottom) wrist and nose coordinates
    /// into `GestureSample`'s `y`-up (`0` = bottom, `1` = top) space by flipping `y = 1.0 - mpY` once.
    /// Set `mirrorX: true` when `x` has not yet been display-mirrored and swipe directions should match a mirrored preview.
    public static func fromMediaPipeNormalized(
        time: Double,
        leftWrist: GesturePoint? = nil,
        rightWrist: GesturePoint? = nil,
        headY: Double? = nil,
        mirrorX: Bool = false,
        bodyMotion: Double? = nil
    ) -> GestureSample {
        func flip(_ point: GesturePoint?) -> GesturePoint? {
            guard let point = point else { return nil }
            let x = mirrorX ? (1.0 - point.x) : point.x
            return GesturePoint(x: x, y: 1.0 - point.y, confidence: point.confidence)
        }
        return GestureSample(
            time: time,
            leftWrist: flip(leftWrist),
            rightWrist: flip(rightWrist),
            headY: headY.map { 1.0 - $0 },
            bodyMotion: bodyMotion
        )
    }

    /// Builds a `GestureSample` in `y`-up coordinates from the 33-element MediaPipe `CalibrationLandmark`
    /// array (`y`-down), reading `leftWrist`, `rightWrist`, and `nose` (`headY`).
    public static func fromMediaPipeNormalized(
        time: Double,
        landmarks: [CalibrationLandmark],
        minConfidence: Double = 0.0,
        mirrorX: Bool = false,
        bodyMotion: Double? = nil
    ) -> GestureSample {
        func landmark(_ name: String) -> CalibrationLandmark? {
            guard let idx = CanonicalSkeleton.mediapipeIndex[name], idx < landmarks.count else { return nil }
            let lm = landmarks[idx]
            guard lm.visibility > 0, lm.visibility >= minConfidence else { return nil }
            return lm
        }
        let lw = landmark("leftWrist").map { GesturePoint(x: $0.x, y: $0.y, confidence: $0.visibility) }
        let rw = landmark("rightWrist").map { GesturePoint(x: $0.x, y: $0.y, confidence: $0.visibility) }
        let head = landmark("nose")?.y
        return fromMediaPipeNormalized(
            time: time,
            leftWrist: lw,
            rightWrist: rw,
            headY: head,
            mirrorX: mirrorX,
            bodyMotion: bodyMotion
        )
    }

    /// Builds a `GestureSample` in `y`-up coordinates from named MediaPipe `CalibrationLandmark`s (`y`-down).
    public static func fromMediaPipeNormalized(
        time: Double,
        named: [String: CalibrationLandmark],
        minConfidence: Double = 0.0,
        mirrorX: Bool = false,
        bodyMotion: Double? = nil
    ) -> GestureSample {
        func point(_ name: String) -> GesturePoint? {
            guard let lm = named[name], lm.visibility > 0, lm.visibility >= minConfidence else { return nil }
            return GesturePoint(x: lm.x, y: lm.y, confidence: lm.visibility)
        }
        let head: Double?
        if let nose = named["nose"], nose.visibility > 0, nose.visibility >= minConfidence {
            head = nose.y
        } else {
            head = nil
        }
        return fromMediaPipeNormalized(
            time: time,
            leftWrist: point("leftWrist"),
            rightWrist: point("rightWrist"),
            headY: head,
            mirrorX: mirrorX,
            bodyMotion: bodyMotion
        )
    }

    /// Computes Ashrium-style normalised `bodyMotion` between two 33-landmark MediaPipe (`y`-down) frames,
    /// matching `CalibrationGate.bodyMotion` (mean shoulder & hip midpoint displacement / nose-to-foot span).
    public static func mediaPipeBodyMotion(
        previous: [CalibrationLandmark]?,
        current: [CalibrationLandmark]
    ) -> Double? {
        guard let prev = previous else { return nil }
        func lm(_ pts: [CalibrationLandmark], _ name: String) -> CalibrationLandmark? {
            guard let idx = CanonicalSkeleton.mediapipeIndex[name], idx < pts.count else { return nil }
            let p = pts[idx]
            return p.visibility > 0 ? p : nil
        }
        guard let ls = lm(current, "leftShoulder"), let rs = lm(current, "rightShoulder"),
              let lh = lm(current, "leftHip"), let rh = lm(current, "rightHip"),
              let nose = lm(current, "nose"),
              let pls = lm(prev, "leftShoulder"), let prs = lm(prev, "rightShoulder"),
              let plh = lm(prev, "leftHip"), let prh = lm(prev, "rightHip") else {
            return nil
        }
        let curSX = 0.5 * (ls.x + rs.x)
        let curSY = 0.5 * (ls.y + rs.y)
        let curHX = 0.5 * (lh.x + rh.x)
        let curHY = 0.5 * (lh.y + rh.y)
        let prevSX = 0.5 * (pls.x + prs.x)
        let prevSY = 0.5 * (pls.y + prs.y)
        let prevHX = 0.5 * (plh.x + prh.x)
        let prevHY = 0.5 * (plh.y + prh.y)
        let footNames = ["leftHeel", "rightHeel", "leftFootIndex", "rightFootIndex"]
        let footY = footNames.compactMap { lm(current, $0)?.y }.max() ?? 1.0
        let span = max(0.05, footY - nose.y)
        let ds = ((curSX - prevSX) * (curSX - prevSX) + (curSY - prevSY) * (curSY - prevSY)).squareRoot()
        let dh = ((curHX - prevHX) * (curHX - prevHX) + (curHY - prevHY) * (curHY - prevHY)).squareRoot()
        return 0.5 * (ds + dh) / span
    }
}

public struct GestureConfig: Sendable, Codable, Equatable {
    /// Wrists below this confidence are treated as missing.
    public var confidenceFloor = 0.5
    /// Minimum seconds between any two emitted commands (except the 2nd clap of a calibration `doubleClap`).
    public var cooldown = 1.0
    /// A gap between samples longer than this clears transient motion tracks.
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

    // Clap & Double Clap
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
    /// Maximum seconds between two claps in `.calibrating` to emit `.doubleClap` (skip calibration).
    public var doubleClapWindow = 1.8

    // Hands raised & stationary hold
    /// Both wrists must exceed headY by this margin.
    public var raisedMargin = 0.05
    /// Seconds the pose must be held in `.betweenTakes`.
    public var raisedHold = 1.0
    /// Seconds the stationary overhead pose must be held in `.countIn`.
    public var countInHold = 1.2
    /// Seconds the stationary overhead pose must be held in `.recording`.
    public var recordingHold = 2.0
    /// Seconds both wrists must remain below `headY` to re-arm overhead hold after firing or phase transition.
    public var lowerHandsRearmDuration = 0.25
    /// Maximum `GestureSample.bodyMotion` allowed during stationary holds in `.countIn` and `.recording`.
    public var stationaryBodyMotionMax = 0.020
    /// Fallback maximum wrist/head speed (normalised image units / second) allowed during stationary holds.
    public var stationaryWristSpeedMax = 0.45

    public init() {}
}

public struct GestureRecognizer: Sendable {

    private struct TrackPoint: Sendable {
        var t: Double
        var x: Double
        var y: Double
    }

    private struct RaisedSnapshot: Sendable {
        var t: Double
        var lx: Double
        var ly: Double
        var rx: Double
        var ry: Double
        var headY: Double
    }

    private static let timeEpsilon = 1e-9

    public let config: GestureConfig

    /// Active mode controlling which gestures can arm and fire. Changing `mode` automatically invokes
    /// `resetPreservingHoldLatch()` so leftover tracks/claps are cleared while an active overhead latch stays safe.
    public var mode: GestureMode {
        didSet {
            if mode != oldValue {
                resetPreservingHoldLatch()
            }
        }
    }

    /// Progress (`0...1`) of an armed, unconsumed overhead hold; `0` when idle, latched, or disabled.
    public private(set) var holdProgress: Double = 0

    /// Most recent event emitted by `processEvent(_:)` / `process(_:)`, or `nil` if the latest sample did not fire.
    public private(set) var lastEvent: GestureEvent?

    /// True while an overhead hold has already fired or was latched across a mode transition and is waiting
    /// for both wrists to drop below `headY` continuously for `config.lowerHandsRearmDuration` (`0.25 s`).
    public var isHoldLatched: Bool {
        raisedConsumed || needsLowerHandsRearm
    }

    private var tracks: [[TrackPoint]] = [[], []]
    private var distances: [(t: Double, d: Double)] = []
    private var lastSampleTime: Double?
    private var lastFire: Double?
    private var clapMeetTime: Double?
    private var lastCalibrationClapTime: Double?
    private var raisedStart: Double?
    private var raisedConsumed = false
    private var needsLowerHandsRearm = false
    private var lowerHandsBelowHeadSince: Double?
    private var lastEitherWristAboveHead = false
    private var prevRaisedSnapshot: RaisedSnapshot?

    public init(config: GestureConfig = GestureConfig(), mode: GestureMode = .betweenTakes) {
        self.config = config
        self.mode = mode
    }

    /// Hard reset clearing all motion history, cooldowns, and the lower-hands hold latch.
    public mutating func reset() {
        tracks = [[], []]
        distances = []
        lastSampleTime = nil
        clapMeetTime = nil
        lastCalibrationClapTime = nil
        raisedStart = nil
        raisedConsumed = false
        needsLowerHandsRearm = false
        lowerHandsBelowHeadSince = nil
        lastEitherWristAboveHead = false
        prevRaisedSnapshot = nil
        holdProgress = 0
        lastEvent = nil
    }

    /// Clears swipe `tracks`, clap `distances`, `clapMeetTime`, and transient timers on phase/mode transitions
    /// while preserving `raisedConsumed = true` whenever an overhead hold already fired or either wrist was
    /// above `headY`, requiring both wrists to drop below `headY` continuously for `0.25 s` before re-arming.
    public mutating func resetPreservingHoldLatch() {
        tracks = [[], []]
        distances = []
        clapMeetTime = nil
        lastCalibrationClapTime = nil
        lastFire = nil
        raisedStart = nil
        prevRaisedSnapshot = nil
        lowerHandsBelowHeadSince = nil
        holdProgress = 0
        lastEvent = nil

        if raisedConsumed || needsLowerHandsRearm || lastEitherWristAboveHead {
            raisedConsumed = true
            needsLowerHandsRearm = true
        } else {
            raisedConsumed = false
            needsLowerHandsRearm = false
        }
    }

    private mutating func resetTransientTracksAfterGap() {
        tracks = [[], []]
        distances = []
        clapMeetTime = nil
        lastCalibrationClapTime = nil
        raisedStart = nil
        prevRaisedSnapshot = nil
        lowerHandsBelowHeadSince = nil
        holdProgress = 0
        if !needsLowerHandsRearm {
            raisedConsumed = false
        }
    }

    /// Feed one sample (monotonically increasing time) and return any legacy 4-case `GestureCommand`.
    /// Note: in `.calibrating`, `.doubleClap` has no legacy 4-case equivalent (`lastEvent == .doubleClap`);
    /// prefer `processEvent(_:)` for v2 callers and `GestureRouter`.
    public mutating func process(_ sample: GestureSample) -> GestureCommand? {
        processEvent(sample)?.legacyCommand
    }

    /// Feed one sample (monotonically increasing time). Returns a `GestureEvent` when a mode-permitted gesture completes.
    public mutating func processEvent(_ sample: GestureSample) -> GestureEvent? {
        lastEvent = nil
        let t = sample.time
        let hands = [usable(sample.leftWrist), usable(sample.rightWrist)]

        if let last = lastSampleTime, t - last > config.maxGap {
            resetTransientTracksAfterGap()
        }
        lastSampleTime = t

        updateLowerHandsRearm(at: t, hands: hands, headY: sample.headY)

        guard mode != .disabled else {
            holdProgress = 0
            return nil
        }

        // Maintain wrist tracks only when swipes are active (`.betweenTakes`).
        if mode == .betweenTakes {
            for i in 0..<2 {
                if let p = hands[i] {
                    tracks[i].append(TrackPoint(t: t, x: p.x, y: p.y))
                    let cutoff = t - (config.swipeWindow + config.swipeQuietDuration + 0.1)
                    tracks[i].removeAll { $0.t < cutoff }
                } else {
                    tracks[i].removeAll()
                }
            }
        } else {
            tracks = [[], []]
        }

        var candidate: GestureEvent?
        var bypassCooldownForDoubleClap = false

        // 1. Hands raised / stationary overhead hold (`.betweenTakes`, `.countIn`, `.recording`)
        if let requiredHold = requiredHoldDuration(for: mode) {
            if let l = hands[0], let r = hands[1], let head = sample.headY,
               l.y > head + config.raisedMargin, r.y > head + config.raisedMargin {
                if !needsLowerHandsRearm && !raisedConsumed {
                    let requiresStillness = (mode == .countIn || mode == .recording)
                    let stationary = !requiresStillness || isStationaryInOverhead(
                        at: t, left: l, right: r, headY: head, bodyMotion: sample.bodyMotion
                    )
                    if stationary {
                        let start = raisedStart ?? t
                        raisedStart = start
                        let elapsed = t - start
                        if elapsed + Self.timeEpsilon >= requiredHold {
                            raisedConsumed = true
                            needsLowerHandsRearm = true
                            lowerHandsBelowHeadSince = nil
                            raisedStart = nil
                            holdProgress = 0
                            candidate = .restartDrill
                        } else {
                            holdProgress = requiredHold > 0 ? min(1.0, max(0.0, elapsed / requiredHold)) : 0
                        }
                    } else {
                        raisedStart = nil
                        holdProgress = 0
                    }
                    prevRaisedSnapshot = RaisedSnapshot(
                        t: t, lx: l.x, ly: l.y, rx: r.x, ry: r.y, headY: head
                    )
                } else {
                    raisedStart = nil
                    prevRaisedSnapshot = nil
                    holdProgress = 0
                }
            } else {
                raisedStart = nil
                prevRaisedSnapshot = nil
                holdProgress = 0
                if !needsLowerHandsRearm {
                    raisedConsumed = false
                }
            }
        } else {
            raisedStart = nil
            prevRaisedSnapshot = nil
            holdProgress = 0
        }

        // 2. Clap & Double-Clap (enabled only in `.betweenTakes` and `.calibrating`)
        if mode == .betweenTakes || mode == .calibrating {
            if let l = hands[0], let r = hands[1] {
                let d = ((l.x - r.x) * (l.x - r.x) + (l.y - r.y) * (l.y - r.y)).squareRoot()
                distances.append((t: t, d: d))
                distances.removeAll { $0.t < t - 1.0 }
                if let meet = clapMeetTime {
                    if d >= config.clapSeparateDistance {
                        clapMeetTime = nil
                        if candidate == nil {
                            if mode == .calibrating,
                               let prevClap = lastCalibrationClapTime,
                               t - prevClap <= config.doubleClapWindow + Self.timeEpsilon {
                                candidate = .doubleClap
                                lastCalibrationClapTime = nil
                                bypassCooldownForDoubleClap = true
                            } else {
                                candidate = .togglePause
                            }
                        }
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
        } else {
            distances.removeAll()
            clapMeetTime = nil
            lastCalibrationClapTime = nil
        }

        // 3. Horizontal Swipe (enabled only in `.betweenTakes`)
        if mode == .betweenTakes && candidate == nil {
            for i in 0..<2 {
                if let c = swipe(track: tracks[i], now: t) {
                    candidate = c
                    break
                }
            }
        }

        guard let event = candidate else { return nil }
        if !bypassCooldownForDoubleClap, let last = lastFire, t - last < config.cooldown {
            return nil
        }
        lastFire = t
        if mode == .calibrating && event == .togglePause {
            lastCalibrationClapTime = t
        }

        // Consume motion history so the same movement cannot re-trigger after cooldown,
        // preserving the current separation point so a fast 2nd clap in `.calibrating` sees hands apart.
        tracks = [[], []]
        if let latestDistance = distances.last {
            distances = [latestDistance]
        } else {
            distances = []
        }
        clapMeetTime = nil
        lastEvent = event
        return event
    }

    private mutating func updateLowerHandsRearm(at t: Double, hands: [GesturePoint?], headY: Double?) {
        guard let head = headY else {
            lowerHandsBelowHeadSince = nil
            return
        }
        let leftAbove = hands[0].map { $0.y >= head } ?? false
        let rightAbove = hands[1].map { $0.y >= head } ?? false
        if leftAbove || rightAbove {
            lastEitherWristAboveHead = true
            lowerHandsBelowHeadSince = nil
        } else if let l = hands[0], let r = hands[1], l.y < head, r.y < head {
            lastEitherWristAboveHead = false
            if needsLowerHandsRearm {
                let since = lowerHandsBelowHeadSince ?? t
                lowerHandsBelowHeadSince = since
                if t - since + Self.timeEpsilon >= config.lowerHandsRearmDuration {
                    needsLowerHandsRearm = false
                    raisedConsumed = false
                    lowerHandsBelowHeadSince = nil
                }
            }
        } else {
            lowerHandsBelowHeadSince = nil
        }
    }

    private func requiredHoldDuration(for mode: GestureMode) -> Double? {
        switch mode {
        case .betweenTakes: return config.raisedHold
        case .countIn: return config.countInHold
        case .recording: return config.recordingHold
        case .calibrating, .disabled: return nil
        }
    }

    private func isStationaryInOverhead(
        at t: Double,
        left: GesturePoint,
        right: GesturePoint,
        headY: Double,
        bodyMotion: Double?
    ) -> Bool {
        if let bodyMotion = bodyMotion, bodyMotion > config.stationaryBodyMotionMax {
            return false
        }
        guard let prev = prevRaisedSnapshot else {
            return true
        }
        let dt = t - prev.t
        guard dt > 1e-6 else { return true }
        let dl = ((left.x - prev.lx) * (left.x - prev.lx) + (left.y - prev.ly) * (left.y - prev.ly)).squareRoot()
        let dr = ((right.x - prev.rx) * (right.x - prev.rx) + (right.y - prev.ry) * (right.y - prev.ry)).squareRoot()
        let dh = abs(headY - prev.headY)
        let maxSpeed = max(dl, dr, dh) / dt
        return maxSpeed <= config.stationaryWristSpeedMax
    }

    private func usable(_ p: GesturePoint?) -> GesturePoint? {
        guard let p = p, p.confidence >= config.confidenceFloor else { return nil }
        return p
    }

    private func swipe(track: [TrackPoint], now: Double) -> GestureEvent? {
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
