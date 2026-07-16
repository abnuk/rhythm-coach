import CoreAudio
import Foundation
import RhythmCore

public struct CalibrationResult: Sendable, Codable {
    public var roundtripSamples: Double
    public var sdSamples: Double
    public var runs: Int
    public var sampleRate: Double

    public var roundtripMs: Double { roundtripSamples / sampleRate * 1000 }
    public var sdMs: Double { sdSamples / sampleRate * 1000 }
}

/// Measures the real output->input round-trip latency: emits a train of
/// clicks at exactly known timeline samples, records the input (physically
/// looped back with a cable, or via a virtual device like BlackHole), and
/// cross-correlates each click. The median delay is the one constant the
/// scorer needs; the reported-property sum is only its fallback estimate.
public enum LoopbackCalibrator {
    public enum CalibrationError: Error, CustomStringConvertible {
        case noSignal
        case unstable(sdSamples: Double)

        public var description: String {
            switch self {
            case .noSignal:
                "no click detected in the input — check the loopback cable and input gain"
            case .unstable(let sd):
                String(format: "measurements unstable (sd %.1f samples) — check signal quality", sd)
            }
        }
    }

    /// Runs the measurement on an already-`configure`d engine. Blocking;
    /// call from a background thread/task.
    public static func measure(engine: DuplexEngine, clicks: Int = 10) throws -> CalibrationResult {
        guard let config = engine.config else { throw HALError.unsupported("engine not configured") }
        let sampleRate = config.sampleRate

        // Quarter notes at 200 BPM = one click every 300 ms; no accents so
        // every click is the identical "beat" template.
        let spec = ClickGridSpec(bpm: 200, subdivision: .quarter, beatsPerBar: 4,
                                 accentDownbeat: false, countInBars: 0)
        let grid = ClickGrid(spec: spec, sampleRate: sampleRate)
        let template = ClickSoundSynth.make(sound: .beep, sampleRate: sampleRate).beat

        let spacing = grid.samplesPerSlot
        let maxDelay = Int(sampleRate * 0.25)  // search window: up to 250 ms RTL
        let recordSamples = Int(spacing * Double(clicks + 1)) + maxDelay

        try engine.start(grid: grid, sound: .beep, clickGain: 0.9, monitorGain: 0)
        defer { engine.stop() }
        guard let ctx = engine.context else { throw HALError.unsupported("no realtime context") }

        // Drain the ring into a linear recording of the whole run.
        var recording = [Float]()
        recording.reserveCapacity(recordSamples + 65536)
        var chunk = [Float](repeating: 0, count: 65536)
        let deadline = Date().addingTimeInterval(Double(recordSamples) / sampleRate + 5)
        while recording.count < recordSamples {
            ctx.dataAvailable.wait()
            while true {
                let n = chunk.withUnsafeMutableBufferPointer {
                    ctx.ring.read(into: $0.baseAddress!, maxCount: $0.count)
                }
                if n == 0 { break }
                recording.append(contentsOf: chunk[0..<n])
            }
            if Date() > deadline {
                throw HALError.unsupported("calibration timed out — no audio callbacks?")
            }
        }

        // Locate each click: search [slotTime, slotTime + maxDelay).
        var delays: [Double] = []
        var peakLevel: Float = 0
        for k in 1...clicks {
            let slotSample = Int(grid.sampleTime(ofSlot: k).rounded())
            let end = min(slotSample + maxDelay + template.count, recording.count)
            guard slotSample < end else { break }
            let segment = Array(recording[slotSample..<end])
            for s in segment where abs(s) > peakLevel { peakLevel = abs(s) }
            if let lag = CrossCorrelator.bestLag(signal: segment, template: template) {
                delays.append(lag)
            }
        }

        guard delays.count >= max(3, clicks / 2), peakLevel > 0.005 else {
            throw CalibrationError.noSignal
        }

        let sorted = delays.sorted()
        let median = sorted[sorted.count / 2]
        // Reject outliers beyond 10 samples from the median, then average.
        let good = delays.filter { abs($0 - median) <= 10 }
        guard good.count >= 3 else { throw CalibrationError.unstable(sdSamples: 999) }
        let mean = good.reduce(0, +) / Double(good.count)
        let variance = good.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(good.count)
        let sd = variance.squareRoot()
        guard sd < 20 else { throw CalibrationError.unstable(sdSamples: sd) }

        return CalibrationResult(
            roundtripSamples: mean,
            sdSamples: sd,
            runs: good.count,
            sampleRate: sampleRate
        )
    }
}
