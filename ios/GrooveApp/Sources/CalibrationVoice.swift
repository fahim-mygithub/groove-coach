import AVFoundation
import GrooveCore

/// Short (~200 ms) `AVAudioEngine` earcons played when hands-free gestures fire (spec §5.4).
enum GestureEarcon: String, Sendable, CaseIterable {
    /// Rising fifth (~200 ms, A5 -> E6) for Start / Confirm.
    case startConfirm
    /// Crisp double-tick (~200 ms, two short D6 ticks) for Next / Repeat.
    case nextRepeat
    /// Descending fourth (~200 ms, E6 -> B5) for Pause / Skip.
    case pauseSkip
}

typealias CalibrationEarcon = GestureEarcon

/// Spoken calibration guidance & audio feedback (spec §2.2, §3.4, §3.5, §4.3, §5.4):
/// - `AVSpeechSynthesizer` at rate `0.52` on a `.playback` session mixing with and ducking other audio.
/// - Dynamic metric distance cues (`CalibrationCue.spokenText(dancerDistanceM:effectiveMinDistanceM:)`).
/// - Rising confirmation chime on each completed step hold, celebratory two-note lock chime on `.locked`,
///   and 200 ms `AVAudioEngine` earcons for recognized hands-free gestures.
@MainActor
final class CalibrationVoice {
    static let cooldownS = 4.0
    static let speechRate: Float = 0.52

    static let plieEntryText = "Arms out, bend your knees into a gentle squat and hold."
    static let studioCalibratedLockedText = "Locked in! Studio calibrated."

    static let airPlayDisconnectedMidTakeText =
        "TV disconnected. Take paused. Reconnect AirPlay, or tap Use Front Camera on your phone."
    static let airPlayDisconnectedMidCalibrationText = "TV disconnected. Calibration paused."
    static let airPlayReconnectedText = "TV reconnected. Raise both hands or clap to resume."

    private let synth = AVSpeechSynthesizer()
    private var lastStep: CalibrationStep?
    private var lastCue: CalibrationCue = .none
    private var lastDancerDistanceM: Double?
    private var lastEffectiveMinDistanceM: Double?
    private var lastSpokenAt: [CalibrationCue: Date] = [:]
    private var lastUtteranceAt: Date?
    private var pending: CalibrationCue?
    private var pendingTextOverride: String?
    private var pendingTask: Task<Void, Never>?
    private var spokeLightTip = false
    private var spokeCameraHeightTip = false
    private var usePlieEntryPromptNext = false

    private let engine = AVAudioEngine()
    private let chimePlayer = AVAudioPlayerNode()
    private let chimeFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var chimeAttached = false

    /// Starts a calibration: forgets cue/step history so the first instruction is spoken cleanly.
    func reset() {
        stop()
        lastStep = nil
        lastCue = .none
        lastDancerDistanceM = nil
        lastEffectiveMinDistanceM = nil
        lastSpokenAt = [:]
        lastUtteranceAt = nil
        spokeLightTip = false
        spokeCameraHeightTip = false
        usePlieEntryPromptNext = false
    }

    func stop() {
        pendingTask?.cancel()
        pendingTask = nil
        pending = nil
        pendingTextOverride = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        if chimeAttached { chimePlayer.stop() }
    }

    // MARK: - Calibration v2 Status Updates (§2.2, §3.4, §3.5)

    /// Primary v2 entrypoint: tracks step transitions (playing per-step confirmation chimes), formats dynamic
    /// `effectiveMinDistanceM` cues, and schedules non-blocking light & LiDAR camera-height advisories.
    func update(status st: CalibrationStatus, calibrationTier: CalibrationResumeTier = .tier2FullCalibration) {
        lastDancerDistanceM = st.dancerDistanceM
        lastEffectiveMinDistanceM = st.effectiveMinDistanceM

        let previousStep = lastStep
        lastStep = st.step

        if st.isLocked {
            if previousStep != .locked {
                pending = nil
                pendingTextOverride = nil
                pendingTask?.cancel()
                if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
                lastCue = st.skipped ? .none : .locked
                if !st.skipped {
                    playChime()
                    let lockText = (calibrationTier == .tier2FullCalibration)
                        ? Self.studioCalibratedLockedText
                        : CalibrationCue.locked.spokenText
                    speakNow(.locked, textOverride: lockText)
                }
            }
            return
        }

        var immediateStepEntry = false
        if let prev = previousStep, prev != st.step {
            if st.step.rawValue > prev.rawValue, prev != .resume {
                // Completed previous step hold: play short rising confirmation chime and speak the next pose immediately.
                pending = nil
                pendingTextOverride = nil
                pendingTask?.cancel()
                if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
                lastUtteranceAt = nil
                lastSpokenAt[st.cue] = nil
                lastCue = .none
                playStepChime()
                immediateStepEntry = true
                if st.step == .plie {
                    usePlieEntryPromptNext = true
                } else {
                    usePlieEntryPromptNext = false
                }
            } else if st.step == .level {
                // Mid-calibration bump reset back to `.level`.
                usePlieEntryPromptNext = false
                lastSpokenAt[.placePhone] = nil
            }
        }

        if st.cue != lastCue {
            lastCue = st.cue
            if st.cue != .none {
                let text = resolvedCueText(
                    for: st.cue,
                    step: st.step,
                    dancerDistanceM: st.dancerDistanceM,
                    effectiveMinDistanceM: st.effectiveMinDistanceM
                )
                if !text.isEmpty {
                    if immediateStepEntry {
                        speakNow(st.cue, textOverride: text)
                    } else {
                        request(st.cue, textOverride: text)
                    }
                }
            }
        }

        update(lightCue: st.lightCue, blockingCue: st.cue)
        update(cameraHeightCue: st.cameraHeightCue, blockingCue: st.cue)
    }

    /// Legacy single-cue entrypoint (preserved for source compatibility).
    func update(
        cue: CalibrationCue,
        dancerDistanceM: Double? = nil,
        effectiveMinDistanceM: Double? = nil
    ) {
        if let dancerDistanceM { lastDancerDistanceM = dancerDistanceM }
        if let effectiveMinDistanceM { lastEffectiveMinDistanceM = effectiveMinDistanceM }

        guard cue != lastCue else { return }
        lastCue = cue
        if cue == .locked {
            pending = nil
            pendingTextOverride = nil
            pendingTask?.cancel()
            if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
            playChime()
            speakNow(.locked)
            return
        }
        let text = cue.spokenText(
            dancerDistanceM: lastDancerDistanceM,
            effectiveMinDistanceM: lastEffectiveMinDistanceM
        )
        guard cue != .none, !text.isEmpty else { return }
        request(cue, textOverride: text)
    }

    /// One spoken lighting tip per calibration (advice only, lower priority than blocking cues).
    func update(lightCue: CalibrationCue, blockingCue: CalibrationCue) {
        guard !spokeLightTip, lightCue != .none, blockingCue == .none || blockingCue == .holdStill else { return }
        guard !synth.isSpeaking, pending == nil else { return }
        spokeLightTip = true
        request(lightCue, textOverride: lightCue.spokenText)
    }

    /// One spoken LiDAR camera-height tip per calibration (`cameraHeightM < 0.50 m` or `> 1.50 m`; §3.4).
    func update(cameraHeightCue: CalibrationCue, blockingCue: CalibrationCue) {
        guard !spokeCameraHeightTip,
              cameraHeightCue.isCameraHeightCue,
              blockingCue == .none || blockingCue == .holdStill else { return }
        guard !synth.isSpeaking, pending == nil else { return }
        spokeCameraHeightTip = true
        request(cameraHeightCue, textOverride: cameraHeightCue.spokenText)
    }

    /// Repeats the active spoken instruction immediately on single-clap in `.calibrating` (§5.2), bypassing cooldown.
    func repeatCurrentCue(dancerDistanceM: Double? = nil, effectiveMinDistanceM: Double? = nil) {
        let dist = dancerDistanceM ?? lastDancerDistanceM
        let effMin = effectiveMinDistanceM ?? lastEffectiveMinDistanceM

        let cueToSpeak: CalibrationCue
        if lastCue != .none && lastCue != .holdStill {
            cueToSpeak = lastCue
        } else if let kind = lastStep?.poseKind {
            cueToSpeak = CalibrationCue(poseCue: kind.entryCue)
        } else if lastStep == .level {
            cueToSpeak = .placePhone
        } else {
            cueToSpeak = lastCue
        }

        let text: String
        if lastStep == .plie && cueToSpeak == .bendKneesDeeper {
            text = Self.plieEntryText
        } else {
            text = cueToSpeak.spokenText(dancerDistanceM: dist, effectiveMinDistanceM: effMin)
        }
        guard !text.isEmpty else { return }

        pending = nil
        pendingTextOverride = nil
        pendingTask?.cancel()
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        speakNow(cueToSpeak, textOverride: text)
    }

    // MARK: - Standalone Announcements (AirPlay Disconnect / Reconnect, §4.3)

    func speakAnnouncement(_ text: String, interrupt: Bool = true) {
        guard !text.isEmpty else { return }
        pending = nil
        pendingTextOverride = nil
        pendingTask?.cancel()
        if interrupt && synth.isSpeaking {
            synth.stopSpeaking(at: .immediate)
        }
        activateSession()
        let u = AVSpeechUtterance(string: text)
        u.rate = Self.speechRate
        u.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        lastUtteranceAt = Date()
        synth.speak(u)
    }

    func speakAirPlayDisconnectedMidTake() {
        speakAnnouncement(Self.airPlayDisconnectedMidTakeText, interrupt: true)
    }

    func speakAirPlayDisconnectedMidCalibration() {
        speakAnnouncement(Self.airPlayDisconnectedMidCalibrationText, interrupt: true)
    }

    func speakAirPlayReconnected() {
        speakAnnouncement(Self.airPlayReconnectedText, interrupt: true)
    }

    // MARK: - Speech Queueing

    private func resolvedCueText(
        for cue: CalibrationCue,
        step: CalibrationStep,
        dancerDistanceM: Double?,
        effectiveMinDistanceM: Double?
    ) -> String {
        if step == .plie && cue == .bendKneesDeeper && usePlieEntryPromptNext {
            usePlieEntryPromptNext = false
            return Self.plieEntryText
        }
        return cue.spokenText(dancerDistanceM: dancerDistanceM, effectiveMinDistanceM: effectiveMinDistanceM)
    }

    private func request(_ cue: CalibrationCue, textOverride: String? = nil) {
        let now = Date()
        if let at = lastSpokenAt[cue], now.timeIntervalSince(at) < Self.cooldownS { return }
        let sinceLast = lastUtteranceAt.map { now.timeIntervalSince($0) } ?? .infinity
        if synth.isSpeaking || sinceLast < 1.0 {
            pending = cue
            pendingTextOverride = textOverride
            schedulePending(after: synth.isSpeaking ? 0.3 : 1.0 - sinceLast)
            return
        }
        speakNow(cue, textOverride: textOverride)
    }

    private func schedulePending(after seconds: Double) {
        pendingTask?.cancel()
        pendingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0.05, seconds) * 1_000_000_000))
            guard let self, !Task.isCancelled, let cue = self.pending else { return }
            if self.synth.isSpeaking {
                self.schedulePending(after: 0.3)
                return
            }
            let overrideText = self.pendingTextOverride
            self.pending = nil
            self.pendingTextOverride = nil
            guard cue == self.lastCue || cue.isAdvisoryCue else { return }
            self.speakNow(cue, textOverride: overrideText)
        }
    }

    private func speakNow(_ cue: CalibrationCue, textOverride: String? = nil) {
        let text = textOverride ?? cue.spokenText(
            dancerDistanceM: lastDancerDistanceM,
            effectiveMinDistanceM: lastEffectiveMinDistanceM
        )
        guard !text.isEmpty else { return }
        activateSession()
        let u = AVSpeechUtterance(string: text)
        u.rate = Self.speechRate
        u.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        let now = Date()
        lastSpokenAt[cue] = now
        lastUtteranceAt = now
        synth.speak(u)
    }

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers, .duckOthers])
        try? session.setActive(true)
    }

    // MARK: - Chimes & Gesture Earcons (§2.2, §5.4)

    /// Plays the celebratory two-note rising lock chime (E6 -> A6, ~0.45 s).
    func playChime() {
        guard let buffer = Self.chimeBuffer(format: chimeFormat) else { return }
        playPCMBuffer(buffer)
    }

    /// Plays a short rising confirmation chime (~0.20 s, C6 -> E6) as each calibration step hold completes (§2.2).
    func playStepChime() {
        guard let buffer = Self.stepChimeBuffer(format: chimeFormat) else { return }
        playPCMBuffer(buffer)
    }

    /// Plays a 200 ms `AVAudioEngine` gesture earcon (§5.4).
    func playEarcon(_ earcon: GestureEarcon) {
        guard let buffer = Self.earconBuffer(earcon, format: chimeFormat) else { return }
        playPCMBuffer(buffer)
    }

    /// Maps a routed `CoachingCommand` to its §5.4 200 ms gesture earcon and plays it.
    func playEarcon(for command: CoachingCommand) {
        playEarcon(Self.earcon(for: command))
    }

    /// Maps a raw `GestureEvent` to its §5.4 200 ms gesture earcon and plays it.
    func playEarcon(for event: GestureEvent) {
        playEarcon(Self.earcon(for: event))
    }

    static func earcon(for command: CoachingCommand) -> GestureEarcon {
        switch command {
        case .startTake, .togglePreviewPlayPause:
            return .startConfirm
        case .nextItem, .restartPreview, .repeatCalibrationCue, .returnToReview:
            return .nextRepeat
        case .pauseTake, .skipCalibration:
            return .pauseSkip
        }
    }

    static func earcon(for event: GestureEvent) -> GestureEarcon {
        switch event {
        case .restartDrill, .togglePause:
            return .startConfirm
        case .swipeLeft, .swipeRight:
            return .nextRepeat
        case .doubleClap:
            return .pauseSkip
        }
    }

    private func playPCMBuffer(_ buffer: AVAudioPCMBuffer) {
        activateSession()
        if !chimeAttached {
            engine.attach(chimePlayer)
            engine.connect(chimePlayer, to: engine.mainMixerNode, format: chimeFormat)
            chimeAttached = true
        }
        if !engine.isRunning {
            do { try engine.start() } catch { return }
        }
        chimePlayer.stop()
        chimePlayer.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        chimePlayer.play()
    }

    /// Final lock chime: two rising bell tones (E6 1318.5 Hz then A6 1760.0 Hz), ~0.45 s.
    static func chimeBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        toneSequenceBuffer(
            notes: [(start: 0.0, freq: 1_318.5, decay: 9.0, gain: 0.35),
                    (start: 0.12, freq: 1_760.0, decay: 9.0, gain: 0.35)],
            duration: 0.45,
            format: format
        )
    }

    /// Per-step hold completion chime: crisp two-note rising confirmation (C6 1046.5 Hz -> E6 1318.5 Hz), ~0.22 s.
    static func stepChimeBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        toneSequenceBuffer(
            notes: [(start: 0.0, freq: 1_046.5, decay: 18.0, gain: 0.28),
                    (start: 0.075, freq: 1_318.5, decay: 15.0, gain: 0.30)],
            duration: 0.22,
            format: format
        )
    }

    /// 200 ms gesture earcon buffers (§5.4):
    /// - `.startConfirm`: rising fifth (A5 880.0 Hz -> E6 1318.5 Hz)
    /// - `.nextRepeat`: double-tick (two short damped D6 1174.7 Hz ticks)
    /// - `.pauseSkip`: descending fourth (E6 1318.5 Hz -> B5 987.8 Hz)
    static func earconBuffer(_ earcon: GestureEarcon, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        switch earcon {
        case .startConfirm:
            return toneSequenceBuffer(
                notes: [(start: 0.0, freq: 880.0, decay: 20.0, gain: 0.30),
                        (start: 0.085, freq: 1_318.5, decay: 18.0, gain: 0.32)],
                duration: 0.20,
                format: format
            )
        case .nextRepeat:
            return toneSequenceBuffer(
                notes: [(start: 0.0, freq: 1_174.7, decay: 38.0, gain: 0.30),
                        (start: 0.09, freq: 1_174.7, decay: 38.0, gain: 0.30)],
                duration: 0.20,
                format: format
            )
        case .pauseSkip:
            return toneSequenceBuffer(
                notes: [(start: 0.0, freq: 1_318.5, decay: 20.0, gain: 0.30),
                        (start: 0.085, freq: 987.8, decay: 18.0, gain: 0.30)],
                duration: 0.20,
                format: format
            )
        }
    }

    private static func toneSequenceBuffer(
        notes: [(start: Double, freq: Double, decay: Double, gain: Double)],
        duration: Double,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let sr = format.sampleRate
        let total = max(1, Int(duration * sr))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)),
              let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(total)
        for i in 0..<total { samples[i] = 0 }
        for note in notes {
            let s0 = max(0, min(total, Int(note.start * sr)))
            for n in 0..<(total - s0) {
                let t = Double(n) / sr
                let attack = min(1.0, t * 400.0)
                let env = exp(-t * note.decay) * attack
                samples[s0 + n] += Float(note.gain * env * sin(2.0 * .pi * note.freq * t))
            }
        }
        return buffer
    }
}

extension CalibrationCue {
    var isLightCue: Bool { self == .dimLight || self == .backlit || self == .veryDark }
    var isCameraHeightCue: Bool { self == .cameraTooLow || self == .cameraTooHigh }
    var isAdvisoryCue: Bool { isLightCue || isCameraHeightCue }
}
