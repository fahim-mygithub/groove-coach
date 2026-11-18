import AVFoundation
import GrooveCore

/// Spoken calibration guidance (spec Q5): `AVSpeechSynthesizer` at rate 0.52 on a `.playback` session that mixes
/// with and ducks other audio. Speaks a cue only when it changes, never repeats a cue within 4 s, and keeps at most
/// one cue pending (the newest wins). Lock plays a short chime plus "Locked in!". No haptics: the phone is on a stand.
@MainActor
final class CalibrationVoice {
    static let cooldownS = 4.0

    private let synth = AVSpeechSynthesizer()
    private var lastCue: CalibrationCue = .none
    private var lastSpokenAt: [CalibrationCue: Date] = [:]
    private var lastUtteranceAt: Date?
    private var pending: CalibrationCue?
    private var pendingTask: Task<Void, Never>?
    private var spokeLightTip = false

    private let engine = AVAudioEngine()
    private let chimePlayer = AVAudioPlayerNode()
    private let chimeFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var chimeAttached = false

    /// Starts a calibration: forgets the cue history so the first instruction is spoken.
    func reset() {
        stop()
        lastCue = .none
        lastSpokenAt = [:]
        lastUtteranceAt = nil
        spokeLightTip = false
    }

    func stop() {
        pendingTask?.cancel()
        pendingTask = nil
        pending = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        chimePlayer.stop()
    }

    /// Feed the blocking cue on every status update; speaks only on a change.
    func update(cue: CalibrationCue) {
        guard cue != lastCue else { return }
        lastCue = cue
        if cue == .locked {
            pending = nil
            pendingTask?.cancel()
            if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
            playChime()
            speakNow(cue)
            return
        }
        guard cue != .none, !cue.spokenText.isEmpty else { return }
        request(cue)
    }

    /// One spoken lighting tip per calibration (advice only, lower priority than the blocking cue).
    func update(lightCue: CalibrationCue, blockingCue: CalibrationCue) {
        guard !spokeLightTip, lightCue != .none, blockingCue == .none || blockingCue == .holdStill else { return }
        guard !synth.isSpeaking, pending == nil else { return }
        spokeLightTip = true
        request(lightCue)
    }

    private func request(_ cue: CalibrationCue) {
        let now = Date()
        if let at = lastSpokenAt[cue], now.timeIntervalSince(at) < Self.cooldownS { return }
        let sinceLast = lastUtteranceAt.map { now.timeIntervalSince($0) } ?? .infinity
        if synth.isSpeaking || sinceLast < 1.0 {
            // Keep only the newest pending cue; say it when the current one finishes.
            pending = cue
            schedulePending(after: synth.isSpeaking ? 0.3 : 1.0 - sinceLast)
            return
        }
        speakNow(cue)
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
            self.pending = nil
            // Only say it if it is still the instruction on screen (or a light tip).
            guard cue == self.lastCue || cue.isLightCue else { return }
            self.speakNow(cue)
        }
    }

    private func speakNow(_ cue: CalibrationCue) {
        let text = cue.spokenText
        guard !text.isEmpty else { return }
        activateSession()
        let u = AVSpeechUtterance(string: text)
        u.rate = 0.52
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

    // MARK: - Chime

    private func playChime() {
        activateSession()
        if !chimeAttached {
            engine.attach(chimePlayer)
            engine.connect(chimePlayer, to: engine.mainMixerNode, format: chimeFormat)
            chimeAttached = true
        }
        if !engine.isRunning {
            do { try engine.start() } catch { return }
        }
        guard let buffer = Self.chimeBuffer(format: chimeFormat) else { return }
        chimePlayer.stop()
        chimePlayer.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        chimePlayer.play()
    }

    /// Two rising bell tones (E6 then A6), about 0.45 s.
    private static func chimeBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sr = format.sampleRate
        let total = Int(0.45 * sr)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)),
              let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(total)
        for i in 0..<total { samples[i] = 0 }
        for (start, freq) in [(0.0, 1_318.5), (0.12, 1_760.0)] {
            let s0 = Int(start * sr)
            for n in 0..<(total - s0) {
                let t = Double(n) / sr
                let env = exp(-t * 9.0) * min(1.0, t * 400.0)
                samples[s0 + n] += Float(0.35 * env * sin(2.0 * .pi * freq * t))
            }
        }
        return buffer
    }
}

extension CalibrationCue {
    var isLightCue: Bool { self == .dimLight || self == .backlit || self == .veryDark }
}
