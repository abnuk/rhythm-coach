import Foundation
import RhythmCore

@MainActor struct ClickGridTests {
    func slotSpacing() {
        let sampleRate = 48000.0
        for bpm in stride(from: 40.0, through: 240.0, by: 7) {
            for sub in Subdivision.allCases {
                let grid = ClickGrid(spec: ClickGridSpec(bpm: bpm, subdivision: sub), sampleRate: sampleRate)
                let perBeat = sampleRate * 60 / bpm
                expect(abs(grid.samplesPerSlot * Double(sub.slotsPerBeat) - perBeat) < 1e-9)
                for i in 0..<64 {
                    expect(abs(grid.sampleTime(ofSlot: i) - Double(i) * grid.samplesPerSlot) < 1e-9)
                    expect(grid.nearestSlot(to: grid.sampleTime(ofSlot: i) + 0.3) == i)
                }
            }
        }
    }

    func slotKinds() {
        let grid = ClickGrid(spec: ClickGridSpec(bpm: 120, subdivision: .sixteenth, beatsPerBar: 4),
                             sampleRate: 44100)
        expect(grid.slotsPerBar == 16)
        for i in 0..<64 {
            switch grid.kind(ofSlot: i) {
            case .downbeat: expect(i % 16 == 0)
            case .beat: expect(i % 16 != 0 && i % 4 == 0)
            case .subdivision: expect(i % 4 != 0)
            }
        }
    }

    func gapPattern() {
        let spec = ClickGridSpec(bpm: 100, subdivision: .eighth, beatsPerBar: 4,
                                 gapPattern: GapPattern(barsOn: 2, barsOff: 2), countInBars: 1)
        let grid = ClickGrid(spec: spec, sampleRate: 44100)
        let slotsPerBar = grid.slotsPerBar
        for slot in 0..<(slotsPerBar * 10) {
            let audible = grid.isAudible(slot: slot)
            if slot < slotsPerBar {
                expect(audible, "count-in must be audible")
            } else {
                let bar = slot / slotsPerBar - 1
                expect(audible == (bar % 4 < 2), "bar \(bar) slot \(slot)")
            }
        }
    }

    func triplets() {
        let grid = ClickGrid(spec: ClickGridSpec(bpm: 90, subdivision: .eighthTriplet), sampleRate: 44100)
        let perBeat = 44100.0 * 60 / 90
        expect(abs(grid.sampleTime(ofSlot: 3) - perBeat) < 1e-9)
        expect(abs(grid.sampleTime(ofSlot: 1) - perBeat / 3) < 1e-9)
    }

    /// Hear 1/4, track 1/16: density thins audible clicks to beats while
    /// every slot remains part of the scored grid.
    func clickDensity() {
        let beats = ClickGrid(
            spec: ClickGridSpec(bpm: 120, subdivision: .sixteenth, beatsPerBar: 4,
                                clickDensity: .beatsOnly, countInBars: 1),
            sampleRate: 44100
        )
        for slot in 0..<64 {
            expect(beats.isAudible(slot: slot) == (slot % 4 == 0),
                   "beatsOnly slot \(slot): audible=\(beats.isAudible(slot: slot))")
        }

        let bars = ClickGrid(
            spec: ClickGridSpec(bpm: 120, subdivision: .eighth, beatsPerBar: 4,
                                clickDensity: .downbeatsOnly, countInBars: 0),
            sampleRate: 44100
        )
        for slot in 0..<32 {
            expect(bars.isAudible(slot: slot) == (slot % 8 == 0),
                   "downbeatsOnly slot \(slot)")
        }

        // Density composes with the gap pattern: beat clicks only, and only
        // in non-gapped bars; count-in keeps its beat clicks.
        let gapped = ClickGrid(
            spec: ClickGridSpec(bpm: 120, subdivision: .sixteenth, beatsPerBar: 4,
                                clickDensity: .beatsOnly,
                                gapPattern: GapPattern(barsOn: 1, barsOff: 1), countInBars: 1),
            sampleRate: 44100
        )
        let slotsPerBar = gapped.slotsPerBar
        for slot in 0..<(slotsPerBar * 6) {
            let onBeat = slot % 4 == 0
            let bar = slot / slotsPerBar
            let expected: Bool
            if bar == 0 {
                expected = onBeat  // count-in
            } else {
                expected = onBeat && (bar - 1) % 2 == 0
            }
            expect(gapped.isAudible(slot: slot) == expected, "gap+density slot \(slot)")
        }
    }
}

@MainActor struct TimingScorerTests {
    let sampleRate = 44100.0

    func makeScorer(targetOffsetMs: Double = 0, compensation: Double = 0) -> TimingScorer {
        let spec = ClickGridSpec(bpm: 120, subdivision: .quarter, countInBars: 1,
                                 targetOffsetMs: targetOffsetMs)
        return TimingScorer(grid: ClickGrid(spec: spec, sampleRate: sampleRate),
                            latencyCompensationSamples: compensation)
    }

    func exactDeviations() {
        let scorer = makeScorer()
        let grid = scorer.grid
        // Slot 2 is in the count-in (4 slots): must be ignored.
        expect(scorer.onOnset(Onset(sampleTime: grid.sampleTime(ofSlot: 2), strength: 1)).isEmpty)

        // Slot 5: exactly 10 ms late.
        let lateBy = 0.010 * sampleRate
        let events = scorer.onOnset(Onset(sampleTime: grid.sampleTime(ofSlot: 5) + lateBy, strength: 1))
        guard case .hit(let hit)? = events.first else {
            recordIssue("expected a hit, got \(events)")
            return
        }
        expect(abs(hit.deviationMs - 10) < 1e-9)
        expect(hit.slotIndex == 5)
        // 10 ms at 120 BPM (500 ms beat) = 2% of IOI.
        expect(abs(hit.deviationPctIOI - 2) < 1e-9)
    }

    func compensation() {
        let comp = 0.020 * sampleRate
        let scorer = makeScorer(compensation: comp)
        let grid = scorer.grid
        let events = scorer.onOnset(Onset(sampleTime: grid.sampleTime(ofSlot: 6) + comp, strength: 1))
        guard case .hit(let hit)? = events.first else {
            recordIssue("expected a hit")
            return
        }
        expect(abs(hit.deviationMs) < 1e-9)
    }

    func targetOffset() {
        let scorer = makeScorer(targetOffsetMs: 15)
        let grid = scorer.grid
        // Playing exactly 15 ms behind the grid = 0 deviation from target.
        let onset = Onset(sampleTime: grid.sampleTime(ofSlot: 5) + 0.015 * sampleRate, strength: 1)
        guard case .hit(let hit)? = scorer.onOnset(onset).first else {
            recordIssue("expected a hit")
            return
        }
        expect(abs(hit.deviationMs) < 1e-9)
        // Playing on the grid = 15 ms early relative to target.
        guard case .hit(let hit2)? = scorer.onOnset(Onset(sampleTime: grid.sampleTime(ofSlot: 6), strength: 1)).first else {
            recordIssue("expected a hit")
            return
        }
        expect(abs(hit2.deviationMs + 15) < 1e-9)
    }

    func slotContention() {
        let scorer = makeScorer()
        let grid = scorer.grid
        let slotTime = grid.sampleTime(ofSlot: 5)
        let first = scorer.onOnset(Onset(sampleTime: slotTime + 0.030 * sampleRate, strength: 1))
        guard case .hit(let hit)? = first.first else {
            recordIssue("first onset must claim the slot, got \(first)")
            return
        }
        expect(abs(hit.deviationMs - 30) < 1e-9)
        // A second onset in the same slot window is extra; the hit stands.
        let second = scorer.onOnset(Onset(sampleTime: slotTime + 0.005 * sampleRate, strength: 1))
        guard case .extra? = second.first, second.count == 1 else {
            recordIssue("second onset must be extra, got \(second)")
            return
        }
        expect(scorer.hits.count == 1 && scorer.hits[0].slotIndex == 5)
    }

    func extraAndMissed() {
        let scorer = makeScorer()
        let grid = scorer.grid
        // 120 BPM quarters: window = min(250, 60) = 60 ms. 100 ms off = extra.
        let events = scorer.onOnset(Onset(sampleTime: grid.sampleTime(ofSlot: 5) + 0.1 * sampleRate, strength: 1))
        expect(events == [.extra(onsetSample: grid.sampleTime(ofSlot: 5) + 0.1 * sampleRate)])

        // Advance past slots 4-7 with only slot 5's neighborhood touched.
        let missed = scorer.advance(to: grid.sampleTime(ofSlot: 8))
        let missedSlots = missed.compactMap { if case .missed(let s) = $0 { s } else { nil } }
        expect(missedSlots.contains(4) && missedSlots.contains(5) && missedSlots.contains(6))
        expect(!missedSlots.contains(0), "count-in slots never reported missed")
    }

    /// deviationPctIOI is % of the played slot interval, not the beat.
    func slotRelativePct() {
        let spec = ClickGridSpec(bpm: 120, subdivision: .eighth, countInBars: 1)
        let grid = ClickGrid(spec: spec, sampleRate: sampleRate)
        let scorer = TimingScorer(grid: grid, latencyCompensationSamples: 0)
        let events = scorer.onOnset(Onset(sampleTime: grid.sampleTime(ofSlot: 9) + 0.010 * sampleRate, strength: 1))
        guard case .hit(let hit)? = events.first else {
            recordIssue("expected a hit, got \(events)")
            return
        }
        // 10 ms on a 250 ms eighth slot = 4%.
        expect(abs(hit.deviationPctIOI - 4) < 1e-9)
    }

    /// With expectEverySlot off, empty slots produce no missed events but
    /// hits are still scored normally.
    func restsAllowed() {
        let spec = ClickGridSpec(bpm: 120, subdivision: .sixteenth, countInBars: 1,
                                 expectEverySlot: false)
        let grid = ClickGrid(spec: spec, sampleRate: sampleRate)
        let scorer = TimingScorer(grid: grid, latencyCompensationSamples: 0)

        // Play only every other slot.
        for slot in stride(from: grid.countInSlots, to: grid.countInSlots + 16, by: 2) {
            let events = scorer.onOnset(Onset(sampleTime: grid.sampleTime(ofSlot: slot) + 0.002 * sampleRate, strength: 1))
            guard case .hit(let hit)? = events.first else {
                recordIssue("expected hit at slot \(slot)")
                return
            }
            expect(abs(hit.deviationMs - 2) < 1e-9)
        }
        let missed = scorer.advance(to: grid.sampleTime(ofSlot: grid.countInSlots + 32))
        expect(missed.isEmpty, "no missed events expected with rests allowed, got \(missed.count)")
        expect(scorer.hits.count == 8)
    }
}

@MainActor struct StatsTests {
    let sampleRate = 44100.0

    func hit(deviationMs: Double, atSecond t: Double) -> ScoredEvent {
        .hit(Hit(slotIndex: 0, gridSample: 0, onsetSample: t * sampleRate,
                 deviationMs: deviationMs, deviationPctIOI: 0, strength: 1))
    }

    func basicMoments() {
        let acc = StatsAccumulator(toleranceMs: 15, sampleRate: sampleRate)
        let devs: [Double] = [10, -5, 0, 20, -10, 5, 15, -20]
        for (i, d) in devs.enumerated() { acc.add(hit(deviationMs: d, atSecond: Double(i))) }
        let s = acc.snapshot()
        let mean = devs.reduce(0, +) / Double(devs.count)
        let variance = devs.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(devs.count - 1)
        expect(abs(s.meanMs - mean) < 1e-9)
        expect(abs(s.sdMs - variance.squareRoot()) < 1e-9)
        expect(s.minMs == -20 && s.maxMs == 20)
        expect(abs(s.pctInTolerance - 6.0 / 8.0 * 100) < 1e-9)
        expect(s.hitCount == 8)
    }

    func driftRamp() {
        let acc = StatsAccumulator(toleranceMs: 15, sampleRate: sampleRate)
        // One hit per second for 3 minutes, deviation ramping 12 ms per minute.
        for i in 0..<180 {
            let minutes = Double(i) / 60
            acc.add(hit(deviationMs: 12 * minutes, atSecond: Double(i)))
        }
        let s = acc.snapshot()
        expect(abs(s.driftMsPerMin - 12) < 0.1)
    }

    func lag1Alternating() {
        let acc = StatsAccumulator(toleranceMs: 15, sampleRate: sampleRate)
        for i in 0..<100 {
            acc.add(hit(deviationMs: i % 2 == 0 ? 10 : -10, atSecond: Double(i)))
        }
        let s = acc.snapshot()
        expect(s.lag1 < -0.9)
    }

    func histogramBins() {
        let acc = StatsAccumulator(toleranceMs: 15, sampleRate: sampleRate)
        acc.add(hit(deviationMs: 0, atSecond: 0))
        acc.add(hit(deviationMs: -99, atSecond: 1))
        acc.add(hit(deviationMs: 99, atSecond: 2))
        acc.add(hit(deviationMs: 500, atSecond: 3))  // clamped to edge
        let s = acc.snapshot()
        expect(s.histogram[Histogram.bin(forDeviationMs: 0)] == 1)
        expect(s.histogram[0] == 1)
        expect(s.histogram[Histogram.binCount - 1] == 2)
        expect(s.histogram.reduce(0, +) == 4)
    }

    func missedExtra() {
        let acc = StatsAccumulator(toleranceMs: 15, sampleRate: sampleRate)
        acc.add(hit(deviationMs: 10, atSecond: 0))
        acc.add(.missed(slotIndex: 3))
        acc.add(.extra(onsetSample: 1234))
        let s = acc.snapshot()
        expect(s.hitCount == 1 && s.missedCount == 1 && s.extraCount == 1)
        expect(abs(s.meanMs - 10) < 1e-9)
    }

    /// The snapshot's rolling SD tracks the last window, not the session.
    func rollingSnapshot() {
        let acc = StatsAccumulator(toleranceMs: 15, sampleRate: sampleRate, slotIOIMs: 250)
        // Below the live minimum: no rolling SD yet, slot IOI stamped.
        for i in 0..<4 { acc.add(hit(deviationMs: i % 2 == 0 ? 40 : -40, atSecond: Double(i))) }
        expect(acc.snapshot().rollingSdMs == nil)
        expect(acc.snapshot().slotIOIMs == 250)
        // 10 wild hits then 16 tight ones: the rolling window is tight while
        // the whole-session SD stays inflated by the wild start.
        for i in 4..<10 { acc.add(hit(deviationMs: i % 2 == 0 ? 40 : -40, atSecond: Double(i))) }
        for i in 10..<26 { acc.add(hit(deviationMs: i % 2 == 0 ? 1 : -1, atSecond: Double(i))) }
        let s = acc.snapshot()
        guard let rolling = s.rollingSdMs else {
            recordIssue("rolling SD expected after 26 hits")
            return
        }
        expect(rolling < 2)
        expect(rolling < s.sdMs)
        expect(s.rating?.stability == .poor, "session rating uses whole-session SD")
    }
}

@MainActor struct LatencyModelTests {
    func compensationPriority() {
        var model = LatencyModel(
            reportedInput: ReportedLatency(deviceLatency: 100, safetyOffset: 50, streamLatency: 10, bufferFrames: 128),
            reportedOutput: ReportedLatency(deviceLatency: 80, safetyOffset: 40, streamLatency: 0, bufferFrames: 128)
        )
        let sr = 48000.0
        expect(model.netCompensationSamples(sampleRate: sr) == 536)

        model.calibratedRoundtripSamples = 700
        expect(model.netCompensationSamples(sampleRate: sr) == 700)

        model.manualOffsetMs = -1
        expect(abs(model.netCompensationSamples(sampleRate: sr) - (700 - 48)) < 1e-9)
    }
}

@MainActor struct CrossCorrelatorTests {
    func templateLocation() {
        let sampleRate = 48000.0
        let template = SignalGenerator.clickBurst(sampleRate: sampleRate, durationMs: 4)
        var signal = [Float](repeating: 0, count: 24000)
        SignalGenerator.addNoiseFloor(&signal, amplitudeDb: -50)
        let truth = 9273
        SignalGenerator.mix(template, into: &signal, at: truth)

        let lag = CrossCorrelator.bestLag(signal: signal, template: template)
        expect(lag != nil)
        if let lag {
            expect(abs(lag - Double(truth)) <= 1.0, "lag \(lag) vs \(truth)")
        }
    }
}
