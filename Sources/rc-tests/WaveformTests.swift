import Foundation
import RhythmCore

@MainActor struct WaveformTests {
    private let sampleRate = 48000.0

    private func randomSignal(count: Int, seed: UInt64) -> [Float] {
        var rng = SignalGenerator.SeededGenerator(seed: seed)
        return (0..<count).map { _ in Float.random(in: -1...1, using: &rng) }
    }

    private func bruteMinMax(_ samples: [Float], _ range: Range<Int>) -> WaveformPeaks.Bucket {
        var lo = samples[range.lowerBound]
        var hi = lo
        for i in range {
            lo = min(lo, samples[i])
            hi = max(hi, samples[i])
        }
        return WaveformPeaks.Bucket(min: lo, max: hi)
    }

    // MARK: - Pyramid

    func pyramidExactOnBucketBoundaries() {
        // Deliberately not a multiple of 16 to exercise the tail bucket.
        let samples = randomSignal(count: 10_007, seed: 11)
        let peaks = WaveformPeaks(samples: samples)
        for level in 0..<peaks.levels.count {
            let bucketSize = 16 << level
            for startBucket in [0, 1, peaks.levels[level].count / 2] {
                let start = startBucket * bucketSize
                guard start < samples.count else { continue }
                let end = min(samples.count, start + bucketSize * 3)
                let got = peaks.minMax(level: level, sampleRange: start..<end)
                let want = bruteMinMax(samples, start..<end)
                expect(got == want, "level \(level) start \(start): \(got) != \(want)")
            }
        }
    }

    func pyramidConservative() {
        let samples = randomSignal(count: 5_000, seed: 22)
        let peaks = WaveformPeaks(samples: samples)
        for level in 0..<peaks.levels.count {
            let bucketSize = 16 << level
            for (start, end) in [(7, 900), (123, 124), (4_990, 5_000), (3, 4_999)] {
                let got = peaks.minMax(level: level, sampleRange: start..<end)
                let true_ = bruteMinMax(samples, start..<end)
                expect(got.min <= true_.min && got.max >= true_.max,
                       "level \(level) [\(start),\(end)): not conservative")
                // Bounds must come from within the bucket-aligned extension.
                let extLo = (start / bucketSize) * bucketSize
                let extHi = min(samples.count, ((end + bucketSize - 1) / bucketSize) * bucketSize)
                let extended = bruteMinMax(samples, extLo..<extHi)
                expect(got == extended, "level \(level) [\(start),\(end)): beyond one bucket")
            }
        }
    }

    func levelSelection() {
        let peaks = WaveformPeaks(samples: randomSignal(count: 100_000, seed: 33))
        expect(peaks.levelIndex(forSamplesPerPoint: 15.9) == 0)
        expect(peaks.levelIndex(forSamplesPerPoint: 16) == 0)
        expect(peaks.levelIndex(forSamplesPerPoint: 31.9) == 0)
        expect(peaks.levelIndex(forSamplesPerPoint: 32) == 1)
        expect(peaks.levelIndex(forSamplesPerPoint: 64) == 2)
        expect(peaks.levelIndex(forSamplesPerPoint: 1e9) == peaks.levels.count - 1)
        expect(peaks.levels.last?.count == 1, "top level collapses to one bucket")
    }

    func columnMinMax() {
        let samples = randomSignal(count: 20_000, seed: 44)
        let data = WaveformData(samples: samples, sampleRate: sampleRate)

        // Raw-backed path (spp < 16) is exact vs brute force.
        for spp in [0.5, 3.0, 15.0] {
            let columns = 50
            let start = 100.0
            let got = data.columnMinMax(startSample: start, samplesPerPoint: spp, columns: columns)
            expect(got.count == columns)
            for c in 0..<columns {
                let lo = max(0, Int((start + Double(c) * spp).rounded(.down)))
                let hi = min(samples.count, max(lo + 1, Int((start + Double(c + 1) * spp).rounded(.up))))
                expect(got[c] == bruteMinMax(samples, lo..<hi), "spp \(spp) column \(c)")
            }
        }

        // Pyramid-backed path: exact when columns are bucket-aligned…
        let aligned = data.columnMinMax(startSample: 0, samplesPerPoint: 32, columns: 20)
        for c in 0..<20 {
            expect(aligned[c] == bruteMinMax(samples, c * 32..<(c + 1) * 32), "aligned column \(c)")
        }
        // …and conservative when they are not.
        let shifted = data.columnMinMax(startSample: 5, samplesPerPoint: 40, columns: 20)
        for c in 0..<20 {
            let lo = 5 + c * 40
            let true_ = bruteMinMax(samples, lo..<(lo + 40))
            expect(shifted[c].min <= true_.min && shifted[c].max >= true_.max, "shifted column \(c)")
        }

        // Columns past the end of the take are zero; a partial tail column is clamped.
        let tail = data.columnMinMax(startSample: 19_990, samplesPerPoint: 8, columns: 4)
        expect(tail[0] == bruteMinMax(samples, 19_990..<19_998))
        expect(tail[1] == bruteMinMax(samples, 19_998..<20_000), "tail column clamps to take end")
        expect(tail[2] == .zero && tail[3] == .zero, "columns beyond the take are zero")
    }

    // MARK: - Viewport

    func viewportRoundTripAndZoom() {
        var vp = WaveformViewport(samplesPerPoint: 100, offsetSamples: 50_000,
                                  widthPoints: 800, totalSamples: 1_000_000)
        for s in [50_000.0, 61_234.5, 130_000.0] {
            expect(abs(vp.sample(atX: vp.x(ofSample: s)) - s) < 1e-6, "round trip \(s)")
        }

        // Zoom keeps the anchor sample stationary (away from clamp edges).
        let anchorX = 400.0
        let anchor = vp.sample(atX: anchorX)
        vp.zoom(by: 0.5, anchorX: anchorX)
        expect(abs(vp.samplesPerPoint - 50) < 1e-9)
        expect(abs(vp.sample(atX: anchorX) - anchor) < 1e-6, "anchor moved on zoom in")
        vp.zoom(by: 2.0, anchorX: anchorX)
        expect(abs(vp.sample(atX: anchorX) - anchor) < 1e-6, "anchor moved on zoom out")

        // Clamping: zooming way out lands exactly at fit; panning stops at edges.
        vp.zoom(by: 1e9, anchorX: 0)
        expect(abs(vp.samplesPerPoint - vp.fitSamplesPerPoint) < 1e-9)
        expect(vp.offsetSamples == 0)
        vp.zoom(by: 1e-12, anchorX: 0)
        expect(abs(vp.samplesPerPoint - 0.5) < 1e-9, "max zoom is 0.5 samples/pt")
        vp.pan(byPoints: -1e12)
        expect(vp.offsetSamples == 0, "clamped at start")
        vp.pan(byPoints: 1e12)
        expect(abs(vp.offsetSamples - (1_000_000 - 800 * vp.samplesPerPoint)) < 1e-6, "clamped at end")

        vp.fit()
        expect(vp.offsetSamples == 0)
        expect(abs(vp.visibleSampleRange.upperBound - 1_000_000) < 1e-6, "fit shows the whole take")

        // A take shorter than the view: fit wins over the 0.5 floor.
        var tiny = WaveformViewport(samplesPerPoint: 1, widthPoints: 800, totalSamples: 100)
        tiny.fit()
        expect(abs(tiny.samplesPerPoint - 100.0 / 800.0) < 1e-9)
    }

    func viewportFollow() {
        let anchor = 300.0  // 900 pt / 3
        var vp = WaveformViewport(samplesPerPoint: 100, offsetSamples: 0,
                                  widthPoints: 900, totalSamples: 1_000_000)
        // Mid-take: the followed sample is pinned exactly at the anchor.
        expect(vp.follow(sample: 500_000) == true)
        expect(abs(vp.x(ofSample: 500_000) - anchor) < 1e-9, "pinned at w/3")
        expect(vp.follow(sample: 500_000) == false, "no change on repeat")

        // Near the start: offset clamps to 0, playhead sits left of the anchor.
        expect(vp.follow(sample: 10_000) == true)
        expect(vp.offsetSamples == 0)
        expect(vp.x(ofSample: 10_000) < anchor)

        // Near the end: clamps to the last page, playhead runs past the anchor.
        expect(vp.follow(sample: 995_000) == true)
        expect(abs(vp.offsetSamples - (1_000_000 - 900 * 100)) < 1e-9)
        expect(vp.x(ofSample: 995_000) > anchor)
        expect(vp.follow(sample: 996_000) == false, "clamped at take end")

        // Custom anchor fraction.
        var centered = WaveformViewport(samplesPerPoint: 100, offsetSamples: 0,
                                        widthPoints: 900, totalSamples: 1_000_000)
        _ = centered.follow(sample: 500_000, anchorFraction: 0.5)
        expect(abs(centered.x(ofSample: 500_000) - 450) < 1e-9)

        var degenerate = WaveformViewport(samplesPerPoint: 1, offsetSamples: 0,
                                          widthPoints: 0, totalSamples: 0)
        expect(degenerate.follow(sample: 100) == false)
    }

    // MARK: - Grid mapping

    func gridMapping() {
        // 90 BPM eighths at 48 kHz: samplesPerSlot = 48000*60/90/2 = 16000.
        let samplesPerSlot = sampleRate * 60 / 90 / 2
        let targetOffsetSamples = 10.0 / 1000 * sampleRate
        let latencySamples = 6.3 / 1000 * sampleRate
        let total = 480_000.0
        let grid = WaveformGridModel(
            samplesPerSlot: samplesPerSlot, slotsPerBeat: 2,
            beatsPerBar: 4, countInSlots: 8,
            originOffsetSamples: targetOffsetSamples + latencySamples,
            totalSamples: total
        )

        for i in [0, 1, 7, 29] {
            let want = Double(i) * 16_000 + 480 + 302.4
            expect(abs(grid.wavSample(ofSlot: i) - want) < 1e-9, "slot \(i)")
        }

        // visibleSlots matches a brute-force scan for several viewports.
        for (offset, spp) in [(0.0, 600.0), (100_000.0, 50.0), (470_000.0, 200.0), (0.0, 1.0)] {
            let vp = WaveformViewport(samplesPerPoint: spp, offsetSamples: offset,
                                      widthPoints: 800, totalSamples: total)
            var brute: [Int] = []
            for i in 0...Int(total / samplesPerSlot) + 1 {
                let s = grid.wavSample(ofSlot: i)
                if s >= max(vp.visibleSampleRange.lowerBound, 0),
                   s <= min(vp.visibleSampleRange.upperBound, total) { brute.append(i) }
            }
            let got = grid.visibleSlots(in: vp)
            if let got {
                expect(Array(got) == brute, "offset \(offset) spp \(spp): \(got) != \(brute)")
            } else {
                expect(brute.isEmpty, "offset \(offset) spp \(spp): expected \(brute)")
            }
        }

        // Line kinds: 4/4 in eighths → slot 0/8 downbeat, even beats, odd subdivisions.
        expect(grid.kind(ofSlot: 0) == .downbeat)
        expect(grid.kind(ofSlot: 2) == .beat)
        expect(grid.kind(ofSlot: 3) == .subdivision)
        expect(grid.kind(ofSlot: 8) == .downbeat)
        let barless = WaveformGridModel(samplesPerSlot: samplesPerSlot, slotsPerBeat: 2)
        expect(barless.kind(ofSlot: 0) == .beat, "no beatsPerBar → no downbeats")
        expect(barless.kind(ofSlot: 4) == .beat)
        expect(barless.kind(ofSlot: 5) == .subdivision)
    }

    func hitDeviationInvariant() {
        // A hit's deviation must equal the on-screen distance between its
        // onset marker and its slot's grid line, in the WAV domain.
        let samplesPerSlot = 16_000.0
        let targetOffsetSamples = 480.0
        let latencySamples = 302.4
        let grid = WaveformGridModel(
            samplesPerSlot: samplesPerSlot, slotsPerBeat: 2,
            originOffsetSamples: targetOffsetSamples + latencySamples,
            totalSamples: 1_000_000
        )
        for (slot, deviationMs) in [(8, -12.5), (9, 0.0), (10, 7.25)] {
            let deviationSamples = deviationMs / 1000 * sampleRate
            // What the scorer stores: compensated onset = reference + deviation.
            let storedOnsetSample = Double(slot) * samplesPerSlot + targetOffsetSamples + deviationSamples
            let onsetWav = storedOnsetSample + latencySamples
            let refWav = grid.wavSample(ofSlot: slot)
            expect(abs((onsetWav - refWav) - deviationSamples) < 1e-9,
                   "slot \(slot) dev \(deviationMs) ms")
        }
    }

    // MARK: - Load

    func loadRoundTrip() throws {
        var signal = [Float](repeating: 0, count: Int(sampleRate) * 2)
        let note = SignalGenerator.pluck(frequency: 110, duration: 0.3, sampleRate: sampleRate)
        SignalGenerator.mix(note, into: &signal, at: 30_000)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rhythmcoach-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try WaveFile.write(samples: signal, sampleRate: sampleRate, to: url)

        let data = try WaveformData.load(url: url)
        expect(data.samples.count == signal.count)
        expect(data.sampleRate == sampleRate)
        expect(data.peaks.sampleCount == signal.count)

        // At fit zoom the pluck region must show energy, silence must not.
        let spp = Double(signal.count) / 800
        let columns = data.columnMinMax(startSample: 0, samplesPerPoint: spp, columns: 800)
        let pluckColumn = Int(30_000 / spp) + 1
        expect(columns[pluckColumn].max > 0.05, "pluck visible at fit zoom")
        expect(columns[700].max == 0 && columns[700].min == 0, "silence stays flat")
    }
}
