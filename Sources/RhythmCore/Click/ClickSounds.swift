import Foundation

/// Click timbres; all synthesized at the session sample rate, no assets.
public enum ClickSound: String, Codable, Sendable, CaseIterable, Identifiable {
    case woodblock
    case beep
    case rim

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .woodblock: "Woodblock"
        case .beep: "Beep"
        case .rim: "Rim"
        }
    }
}

/// Synthesizes short click PCM buffers. The attack is placed at sample 0 so
/// a click scheduled at slot time S is *heard* starting exactly at S.
public enum ClickSoundSynth {
    /// Returns (downbeat, beat, subdivision) buffers.
    public static func make(sound: ClickSound, sampleRate: Double) -> (accent: [Float], beat: [Float], sub: [Float]) {
        switch sound {
        case .woodblock:
            return (
                tone(frequency: 1760, decayMs: 25, noiseMs: 1.5, gain: 0.9, sampleRate: sampleRate),
                tone(frequency: 1175, decayMs: 22, noiseMs: 1.2, gain: 0.7, sampleRate: sampleRate),
                tone(frequency: 880, decayMs: 18, noiseMs: 0.8, gain: 0.45, sampleRate: sampleRate)
            )
        case .beep:
            return (
                tone(frequency: 1500, decayMs: 35, noiseMs: 0, gain: 0.8, sampleRate: sampleRate),
                tone(frequency: 1000, decayMs: 30, noiseMs: 0, gain: 0.6, sampleRate: sampleRate),
                tone(frequency: 750, decayMs: 22, noiseMs: 0, gain: 0.4, sampleRate: sampleRate)
            )
        case .rim:
            return (
                tone(frequency: 3200, decayMs: 12, noiseMs: 2.5, gain: 0.9, sampleRate: sampleRate),
                tone(frequency: 2400, decayMs: 10, noiseMs: 2.0, gain: 0.7, sampleRate: sampleRate),
                tone(frequency: 1800, decayMs: 8, noiseMs: 1.5, gain: 0.45, sampleRate: sampleRate)
            )
        }
    }

    /// Exponentially decaying sine with a short noise transient, 1 ms fade-in.
    private static func tone(frequency: Double, decayMs: Double, noiseMs: Double, gain: Float, sampleRate: Double) -> [Float] {
        let length = Int(sampleRate * decayMs * 5 / 1000)
        var out = [Float](repeating: 0, count: max(length, 32))
        let decayPerSample = Foundation.exp(-1.0 / (decayMs / 1000 * sampleRate / 5))
        var amp = 1.0
        let omega = 2.0 * Double.pi * frequency / sampleRate
        var rng = SystemRandomNumberGenerator()
        let noiseSamples = Int(noiseMs / 1000 * sampleRate)
        let fadeInSamples = max(1, Int(0.001 * sampleRate))
        for i in 0..<out.count {
            var s = Foundation.sin(omega * Double(i)) * amp
            if i < noiseSamples {
                s += (Double.random(in: -1...1, using: &rng)) * 0.5 * amp
            }
            if i < fadeInSamples {
                s *= Double(i) / Double(fadeInSamples)
            }
            out[i] = Float(s) * gain
            amp *= decayPerSample
        }
        return out
    }
}
