import Foundation

/// Host screen sharing `GestureRouter` (spec §5.1, §5.2).
public enum CoachingHost: String, Sendable, Codable, Equatable {
    /// `PracticeView` / `PracticeViewModel`: single-move practice loop (moves always unlocked, no preview player).
    case practice
    /// `LessonPlayerView` / `LessonPlayerViewModel`: multi-segment lesson with teacher preview video and unlock gate.
    case lesson
}

/// Coaching screen phase mapped onto `GestureMode` and `CoachingCommand` (spec §5.2).
public enum CoachingPhase: String, Sendable, Codable, Equatable, CaseIterable {
    case idle
    case calibrating
    case clapSync
    case countIn
    case recording
    case analyzing
    case results
    case paused

    /// `GestureMode` active during this coaching phase.
    public var gestureMode: GestureMode {
        switch self {
        case .idle, .results, .paused:
            return .betweenTakes
        case .calibrating:
            return .calibrating
        case .countIn:
            return .countIn
        case .recording:
            return .recording
        case .analyzing, .clapSync:
            return .disabled
        }
    }
}

/// High-level coaching UI action produced by `GestureRouter` (spec §5.2, §10 #12–#14).
public enum CoachingCommand: String, Sendable, Codable, Equatable, CaseIterable {
    /// Start or repeat a take (from `.idle`, `.results`, or `.paused`).
    case startTake
    /// Cancel `.countIn` or emergency-pause `.recording` into `.paused` (`abortTake(to: .paused)`).
    case pauseTake
    /// Play / pause the teacher preview video in `.idle` (`LessonPlayer`).
    case togglePreviewPlayPause
    /// Restart the segment preview video from `startS` in `.idle` (`LessonPlayer`).
    case restartPreview
    /// Advance to the next unlocked lesson segment or next practice move.
    case nextItem
    /// Dismiss `.results` (when next segment is locked) or exit `.paused` back to lesson/practice review (`.idle`).
    case returnToReview
    /// Repeat the active spoken calibration cue (`CalibrationVoice`).
    case repeatCalibrationCue
    /// Skip calibration (`CalibrationController.skip()`).
    case skipCalibration
}

/// Outcome of routing one recognized gesture in `GestureRouter`.
public struct RoutedGesture: Sendable, Codable, Equatable {
    public var event: GestureEvent
    public var mode: GestureMode
    public var phase: CoachingPhase
    public var command: CoachingCommand

    public init(event: GestureEvent, mode: GestureMode, phase: CoachingPhase, command: CoachingCommand) {
        self.event = event
        self.mode = mode
        self.phase = phase
        self.command = command
    }
}

/// Pure, Foundation-only router mapping `GestureEvent`s across `CoachingPhase`s into `CoachingCommand`s,
/// enforcing mode synchronization, `resetPreservingHoldLatch()` on transitions, and the `1.0 s`
/// post-take `.results` grace cooldown (spec §5.2, §5.3).
public struct GestureRouter: Sendable, Equatable {

    private static let timeEpsilon = 1e-9

    public var host: CoachingHost
    public private(set) var phase: CoachingPhase
    /// Duration (seconds) after entering `.results` during which gestures are ignored so a final dance flourish
    /// cannot dismiss the scorecard (§5.3).
    public var postTakeGraceDuration: Double

    private var resultsGraceStart: Double?
    private var pendingResultsGraceAnchor = false

    public var gestureMode: GestureMode {
        phase.gestureMode
    }

    public init(
        host: CoachingHost = .lesson,
        phase: CoachingPhase = .idle,
        postTakeGraceDuration: Double = 1.0
    ) {
        self.host = host
        self.phase = phase
        self.postTakeGraceDuration = postTakeGraceDuration
        if phase == .results {
            self.pendingResultsGraceAnchor = true
        }
    }

    /// Transitions to `newPhase`, arming the post-take grace window when entering `.results`.
    public mutating func transition(to newPhase: CoachingPhase, at time: Double? = nil) {
        guard newPhase != phase else { return }
        phase = newPhase
        if newPhase == .results {
            resultsGraceStart = time
            pendingResultsGraceAnchor = (time == nil)
        } else {
            resultsGraceStart = nil
            pendingResultsGraceAnchor = false
        }
    }

    /// Transitions to `newPhase`, synchronises `recognizer.mode`, and invokes `recognizer.resetPreservingHoldLatch()`.
    public mutating func transition(
        to newPhase: CoachingPhase,
        at time: Double? = nil,
        recognizer: inout GestureRecognizer
    ) {
        transition(to: newPhase, at: time)
        let targetMode = newPhase.gestureMode
        if recognizer.mode != targetMode {
            recognizer.mode = targetMode
        } else {
            recognizer.resetPreservingHoldLatch()
        }
    }

    /// Feeds one `GestureSample` through `recognizer` (ensuring `recognizer.mode` matches `phase.gestureMode`)
    /// and routes any emitted event into a `RoutedGesture`.
    public mutating func process(
        _ sample: GestureSample,
        recognizer: inout GestureRecognizer,
        passed: Bool = false,
        nextUnlocked: Bool = false
    ) -> RoutedGesture? {
        if recognizer.mode != phase.gestureMode {
            recognizer.mode = phase.gestureMode
        }
        anchorResultsGraceIfNeeded(at: sample.time)
        guard let event = recognizer.processEvent(sample) else { return nil }
        guard let command = route(event, at: sample.time, passed: passed, nextUnlocked: nextUnlocked) else {
            return nil
        }
        return RoutedGesture(event: event, mode: phase.gestureMode, phase: phase, command: command)
    }

    /// Routes an already-recognized `GestureEvent` in the current `phase`, enforcing the `.results` grace cooldown.
    public mutating func route(
        _ event: GestureEvent,
        at time: Double? = nil,
        passed: Bool = false,
        nextUnlocked: Bool = false
    ) -> CoachingCommand? {
        if let time = time {
            anchorResultsGraceIfNeeded(at: time)
            if isInResultsGraceWindow(at: time) {
                return nil
            }
        } else if phase == .results && pendingResultsGraceAnchor && postTakeGraceDuration > 0 {
            return nil
        }
        return Self.route(
            event,
            phase: phase,
            host: host,
            passed: passed,
            nextUnlocked: nextUnlocked
        )
    }

    /// Convenience overload routing a legacy 4-case `GestureCommand`.
    public mutating func route(
        legacyCommand command: GestureCommand,
        at time: Double? = nil,
        passed: Bool = false,
        nextUnlocked: Bool = false
    ) -> CoachingCommand? {
        route(GestureEvent(command), at: time, passed: passed, nextUnlocked: nextUnlocked)
    }

    /// Returns true while `phase == .results` and `time` is still within `postTakeGraceDuration` of entering `.results`.
    public func isInResultsGraceWindow(at time: Double) -> Bool {
        guard phase == .results, postTakeGraceDuration > 0, let start = resultsGraceStart else {
            return false
        }
        return time - start + Self.timeEpsilon < postTakeGraceDuration
    }

    private mutating func anchorResultsGraceIfNeeded(at time: Double) {
        if phase == .results && pendingResultsGraceAnchor {
            resultsGraceStart = time
            pendingResultsGraceAnchor = false
        }
    }

    /// Pure stateless phase-matrix mapping (spec §5.2 table).
    public static func route(
        _ event: GestureEvent,
        phase: CoachingPhase,
        host: CoachingHost = .lesson,
        passed: Bool = false,
        nextUnlocked: Bool = false
    ) -> CoachingCommand? {
        let canAdvance = (host == .practice) || nextUnlocked

        switch phase {
        case .idle:
            switch event {
            case .togglePause:
                return host == .practice ? .startTake : .togglePreviewPlayPause
            case .doubleClap:
                return nil
            case .restartDrill:
                return .startTake
            case .swipeLeft:
                return host == .practice ? .startTake : .restartPreview
            case .swipeRight:
                return canAdvance ? .nextItem : nil
            }

        case .calibrating:
            switch event {
            case .togglePause:
                return .repeatCalibrationCue
            case .doubleClap:
                return .skipCalibration
            case .restartDrill, .swipeLeft, .swipeRight:
                return nil
            }

        case .countIn, .recording:
            switch event {
            case .restartDrill:
                return .pauseTake
            case .togglePause, .doubleClap, .swipeLeft, .swipeRight:
                return nil
            }

        case .analyzing, .clapSync:
            return nil

        case .results:
            switch event {
            case .togglePause:
                return (passed && canAdvance) ? .nextItem : .startTake
            case .doubleClap:
                return nil
            case .restartDrill, .swipeLeft:
                return .startTake
            case .swipeRight:
                return canAdvance ? .nextItem : .returnToReview
            }

        case .paused:
            switch event {
            case .togglePause, .restartDrill:
                return .startTake
            case .doubleClap:
                return nil
            case .swipeLeft:
                return .returnToReview
            case .swipeRight:
                return canAdvance ? .nextItem : nil
            }
        }
    }

    /// Pure stateless phase-matrix overload for legacy 4-case `GestureCommand`.
    public static func route(
        legacyCommand command: GestureCommand,
        phase: CoachingPhase,
        host: CoachingHost = .lesson,
        passed: Bool = false,
        nextUnlocked: Bool = false
    ) -> CoachingCommand? {
        route(GestureEvent(command), phase: phase, host: host, passed: passed, nextUnlocked: nextUnlocked)
    }
}
