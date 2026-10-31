import AVFoundation

/// Sample-accurate click track for practice takes: one pre-rendered buffer started at a known host time, so camera
/// frames (host-clock timestamps) and beats share the same timeline.
final class Metronome {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private let sampleRate = 44_100.0

    init() {
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    /// Output latency of the current route (ms); speakers ~10 ms, Bluetooth often 150+ ms. Passed to scoring as
    /// `audio_latency_ms` because the dancer reacts to the click they hear, not to when it was rendered.
    var outputLatencyMs: Double {
        AVAudioSession.sharedInstance().outputLatency * 1000.0
    }

    /// Plays clicks at `clickTimes` (seconds from the start) and returns the host-clock time (seconds) of that start.
    /// `accented` clicks are higher pitched (used for the count-in).
    func start(clickTimes: [Double], accented: Set<Int>, duration: Double) throws -> Double {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
        if !engine.isRunning {
            try engine.start()
        }

        let frameCount = AVAudioFrameCount(max(1.0, duration * sampleRate))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let samples = buffer.floatChannelData?[0] else {
            throw NSError(domain: "Metronome", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not allocate click buffer"])
        }
        buffer.frameLength = frameCount
        let total = Int(frameCount)
        for i in 0..<total { samples[i] = 0.0 }

        let clickLength = Int(0.035 * sampleRate)
        for (index, time) in clickTimes.enumerated() {
            let startSample = Int((time * sampleRate).rounded())
            let freq = accented.contains(index) ? 1_760.0 : 1_175.0
            for n in 0..<clickLength where startSample + n >= 0 && startSample + n < total {
                let t = Double(n) / sampleRate
                let envelope = exp(-t * 90.0)
                samples[startSample + n] += Float(0.8 * envelope * sin(2.0 * Double.pi * freq * t))
            }
        }

        player.stop()
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        let startHostTime = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.25)
        player.play(at: AVAudioTime(hostTime: startHostTime))
        return AVAudioTime.seconds(forHostTime: startHostTime)
    }

    func stop() {
        player.stop()
    }
}
