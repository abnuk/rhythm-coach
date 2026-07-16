import Foundation
import RhythmCore

/// Full-pipeline simulation: a "player" with a known bias and jitter plays
/// plucks against the grid; their sound reaches the input buffer after a
/// round-trip latency. Detector -> scorer -> stats must recover the bias and
/// jitter within tight bounds. This is the synthetic-audio equivalent of the
/// loopback self-test.
@MainActor struct EndToEndSessionTests {
    func biasAndJitterRecovery() {
        let sampleRate = 44100.0
        let roundtripSamples = 612.0  // simulated output+input latency
        let biasMs = 12.0
        let jitterPatternMs: [Double] = [0, 3, -3, 2, -2, 1, -1, 2.5, -2.5, 0]

        let spec = ClickGridSpec(bpm: 100, subdivision: .eighth, countInBars: 1)
        let grid = ClickGrid(spec: spec, sampleRate: sampleRate)

        let playedSlots = grid.countInSlots..<(grid.countInSlots + 40)
        let lastSlotTime = grid.sampleTime(ofSlot: playedSlots.upperBound)
        var signal = [Float](repeating: 0, count: Int(lastSlotTime) + Int(sampleRate))
        SignalGenerator.addNoiseFloor(&signal, amplitudeDb: -66)

        var expectedDeviations: [Double] = []
        for (k, slot) in playedSlots.enumerated() {
            let jitter = jitterPatternMs[k % jitterPatternMs.count]
            let deviationMs = biasMs + jitter
            expectedDeviations.append(deviationMs)
            let position = grid.sampleTime(ofSlot: slot) + deviationMs / 1000 * sampleRate + roundtripSamples
            let note = SignalGenerator.pluck(
                frequency: [82.41, 110, 146.83, 196][k % 4],
                duration: 0.25, sampleRate: sampleRate,
                amplitude: 0.4, seed: UInt64(k + 100)
            )
            SignalGenerator.mix(note, into: &signal, at: Int(position.rounded()))
        }

        let detector = OnsetDetector(sampleRate: sampleRate)
        let scorer = TimingScorer(grid: grid, latencyCompensationSamples: roundtripSamples)
        let stats = StatsAccumulator(toleranceMs: 20, sampleRate: sampleRate)

        let detected = detector.detect(in: signal)
        if detected.count != playedSlots.count {
            print("    [diag] detected \(detected.count) onsets, played \(playedSlots.count)")
            for onset in detected {
                let raw = onset.sampleTime - roundtripSamples
                let slot = grid.nearestSlot(to: raw)
                let devMs = (raw - grid.sampleTime(ofSlot: slot)) / sampleRate * 1000
                print(String(format: "    [diag] onset %.0f -> slot %d dev %+.1f ms strength %.3f",
                             onset.sampleTime, slot, devMs, onset.strength))
            }
        }
        for onset in detected {
            for event in scorer.onOnset(onset) {
                stats.add(event)
            }
        }
        // Advance only through the played range: the silent tail after the
        // last note is legitimately full of "missed" slots.
        for event in scorer.advance(to: grid.sampleTime(ofSlot: playedSlots.upperBound - 1) + roundtripSamples) {
            stats.add(event)
        }

        let s = stats.snapshot()
        let expectedMean = expectedDeviations.reduce(0, +) / Double(expectedDeviations.count)
        let expectedVar = expectedDeviations
            .map { ($0 - expectedMean) * ($0 - expectedMean) }
            .reduce(0, +) / Double(expectedDeviations.count - 1)

        expect(s.hitCount == playedSlots.count, "hits \(s.hitCount) of \(playedSlots.count)")
        expect(s.missedCount == 0)
        expect(abs(s.meanMs - expectedMean) < 1.5,
                "mean \(s.meanMs) vs expected \(expectedMean)")
        expect(abs(s.sdMs - expectedVar.squareRoot()) < 1.5,
                "sd \(s.sdMs) vs expected \(expectedVar.squareRoot())")
        expect(abs(s.driftMsPerMin) < 3, "no drift injected, got \(s.driftMsPerMin)")
    }

    func driftDetection() {
        let sampleRate = 44100.0
        let spec = ClickGridSpec(bpm: 120, subdivision: .quarter, countInBars: 1)
        let grid = ClickGrid(spec: spec, sampleRate: sampleRate)

        // Player starts on the grid and rushes progressively: -30 ms/min drift.
        let driftMsPerMin = -30.0
        let playedSlots = grid.countInSlots..<(grid.countInSlots + 60)
        let lastSlotTime = grid.sampleTime(ofSlot: playedSlots.upperBound)
        var signal = [Float](repeating: 0, count: Int(lastSlotTime) + Int(sampleRate))

        for (k, slot) in playedSlots.enumerated() {
            let slotTime = grid.sampleTime(ofSlot: slot)
            let minutes = slotTime / sampleRate / 60
            let deviationMs = driftMsPerMin * minutes
            let position = slotTime + deviationMs / 1000 * sampleRate
            let note = SignalGenerator.pluck(frequency: 110, duration: 0.2, sampleRate: sampleRate,
                                             amplitude: 0.4, seed: UInt64(k + 500))
            SignalGenerator.mix(note, into: &signal, at: Int(position.rounded()))
        }

        let detector = OnsetDetector(sampleRate: sampleRate)
        let scorer = TimingScorer(grid: grid, latencyCompensationSamples: 0)
        let stats = StatsAccumulator(toleranceMs: 20, sampleRate: sampleRate)
        for onset in detector.detect(in: signal) {
            for event in scorer.onOnset(onset) { stats.add(event) }
        }

        let s = stats.snapshot()
        expect(s.hitCount == playedSlots.count)
        expect(abs(s.driftMsPerMin - driftMsPerMin) < 4,
                "drift \(s.driftMsPerMin) vs expected \(driftMsPerMin)")
        expect(s.meanMs < 0, "rushing player must show negative bias")
    }
}
