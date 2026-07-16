import Foundation
import RhythmCore

/// Deterministic test-signal synthesis: plucked strings (Karplus-Strong),
/// chord strums, click bursts and noise beds with exactly known onset times.
enum SignalGenerator {
    struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
    }

    /// Karplus-Strong plucked string starting at sample 0 of the returned buffer.
    static func pluck(frequency: Double, duration: Double, sampleRate: Double,
                      amplitude: Float = 0.5, damping: Float = 0.996, seed: UInt64 = 1) -> [Float] {
        let n = Int(duration * sampleRate)
        let period = max(2, Int(sampleRate / frequency))
        var rng = SeededGenerator(seed: seed)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<min(period, n) {
            out[i] = Float.random(in: -1...1, using: &rng) * amplitude
        }
        if n > period + 1 {
            for i in (period + 1)..<n {
                out[i] = damping * 0.5 * (out[i - period] + out[i - period - 1])
            }
        }
        // Fade the tail out so the buffer end is not an audible click
        // (a hard truncation of a still-ringing string IS a real onset).
        let fade = min(Int(0.03 * sampleRate), n)
        for i in 0..<fade {
            let x = Double(i) / Double(fade)
            out[n - 1 - i] *= Float(0.5 - 0.5 * cos(.pi * x))
        }
        return out
    }

    /// A short filtered-noise-plus-tone burst (metronome-click-like).
    static func clickBurst(sampleRate: Double, durationMs: Double = 5,
                           frequency: Double = 2000, amplitude: Float = 0.8) -> [Float] {
        let n = Int(durationMs / 1000 * sampleRate)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let env = Float(exp(-Double(i) / (Double(n) / 4)))
            out[i] = Float(sin(2 * .pi * frequency * Double(i) / sampleRate)) * env * amplitude
        }
        return out
    }

    /// Mixes `event` into `buffer` starting at `position` (additive, clipped to bounds).
    static func mix(_ event: [Float], into buffer: inout [Float], at position: Int) {
        for i in 0..<event.count {
            let j = position + i
            if j >= 0 && j < buffer.count {
                buffer[j] += event[i]
            }
        }
    }

    /// A chord strum: notes staggered by `spreadMs / (count-1)` each.
    /// The onset (first string) is at the mix position.
    static func strum(frequencies: [Double], spreadMs: Double, duration: Double,
                      sampleRate: Double, amplitude: Float = 0.35, seed: UInt64 = 7) -> [Float] {
        let spreadSamples = Int(spreadMs / 1000 * sampleRate)
        let perString = frequencies.count > 1 ? spreadSamples / (frequencies.count - 1) : 0
        var out = [Float](repeating: 0, count: Int(duration * sampleRate) + spreadSamples)
        for (k, f) in frequencies.enumerated() {
            let note = pluck(frequency: f, duration: duration, sampleRate: sampleRate,
                             amplitude: amplitude, seed: seed &+ UInt64(k))
            mix(note, into: &out, at: k * perString)
        }
        return out
    }

    /// Low-level uniform noise floor across the whole buffer.
    static func addNoiseFloor(_ buffer: inout [Float], amplitudeDb: Double, seed: UInt64 = 42) {
        let amp = Float(pow(10, amplitudeDb / 20))
        var rng = SeededGenerator(seed: seed)
        for i in 0..<buffer.count {
            buffer[i] += Float.random(in: -1...1, using: &rng) * amp
        }
    }

    /// E major chord fundamentals (guitar, standard tuning).
    static let eMajor: [Double] = [82.41, 123.47, 164.81, 207.65, 246.94, 329.63]
}
