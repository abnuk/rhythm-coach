import Foundation
import RhythmCore

@main
struct Runner {
    @MainActor
    static func main() async {
        suite("OnsetDetector on synthesized guitar signals")
        let onset = OnsetDetectorTests()
        runTest("click bursts within ±3 ms") { onset.clickBursts() }
        runTest("single plucks within ±3 ms") { onset.singlePlucks() }
        runTest("chord strums: one onset each") { onset.chordStrums() }
        runTest("minIOI merges 25 ms double hit") { onset.minIOIMerging() }
        runTest("noise floor: no onsets") { onset.noiseFloorSilence() }
        runTest("quiet after loud (whitening)") { onset.quietAfterLoud() }
        runTest("decay tail: no false onset") { onset.decayTailNoFalseOnset() }
        runTest("ghost over ringing tail") { onset.ghostOverRingingTail() }
        runTest("buried ghost: no early anchor") { onset.buriedGhostNoEarlyAnchor() }
        runTest("streaming == offline (beating tail)") { onset.beatingTailStreamingEquivalence() }
        runTest("streaming == offline") { onset.streamingEquivalence() }
        runTest("WAV roundtrip") { try onset.wavRoundtrip() }

        suite("ClickGrid")
        let grid = ClickGridTests()
        runTest("slot spacing exact") { grid.slotSpacing() }
        runTest("slot kinds") { grid.slotKinds() }
        runTest("gap pattern") { grid.gapPattern() }
        runTest("triplets") { grid.triplets() }
        runTest("click density decoupled from tracking") { grid.clickDensity() }

        suite("TimingScorer")
        let scorer = TimingScorerTests()
        runTest("exact deviations, count-in ignored") { scorer.exactDeviations() }
        runTest("latency compensation") { scorer.compensation() }
        runTest("target offset mode") { scorer.targetOffset() }
        runTest("slot contention") { scorer.slotContention() }
        runTest("extra and missed") { scorer.extraAndMissed() }
        runTest("rests allowed (expectEverySlot off)") { scorer.restsAllowed() }
        runTest("pct relative to slot, not beat") { scorer.slotRelativePct() }

        suite("Stats")
        let stats = StatsTests()
        runTest("moments closed-form") { stats.basicMoments() }
        runTest("drift ramp") { stats.driftRamp() }
        runTest("lag-1 alternating") { stats.lag1Alternating() }
        runTest("histogram bins") { stats.histogramBins() }
        runTest("missed/extra counting") { stats.missedExtra() }
        runTest("rolling SD in snapshot") { stats.rollingSnapshot() }

        suite("TimingRating")
        let rating = TimingRatingTests()
        runTest("floor regime boundaries") { rating.floorRegime() }
        runTest("percent regime boundaries") { rating.percentRegime() }
        runTest("floor/percent crossover") { rating.crossover() }
        runTest("sign and nil cases") { rating.signAndNil() }
        runTest("overall combination rule") { rating.overallRule() }

        suite("TargetLevel")
        let target = TargetLevelTests()
        runTest("floor regime windows") { target.floorRegime() }
        runTest("percent regime + 60 ms cap") { target.percentRegimeAndCap() }
        runTest("floor/percent crossover") { target.crossover() }
        runTest("fast subdivision match-window cap") { target.fastSubdivisionCap() }
        runTest("sigma × tier-limit consistency") { target.sigmaConsistency() }
        runTest("rawValue round trip") { target.rawValueRoundTrip() }

        suite("RollingStats")
        let rolling = RollingStatsTests()
        runTest("fewer than window → empty") { rolling.tooFew() }
        runTest("constant input") { rolling.constantInput() }
        runTest("closed-form single window") { rolling.closedFormWindow() }
        runTest("tight then loose rises") { rolling.tightThenLoose() }

        suite("LatencyModel")
        runTest("compensation priority") { LatencyModelTests().compensationPriority() }

        suite("CrossCorrelator")
        runTest("template location in noise") { CrossCorrelatorTests().templateLocation() }

        suite("ClickRenderer")
        let renderer = ClickRendererTests()
        runTest("sample accuracy across callbacks") { renderer.sampleAccuracy() }
        runTest("beats-only density renders quarter clicks") { renderer.densityAudio() }
        runTest("gap bars silent") { renderer.gapSilence() }

        suite("End-to-end simulated session")
        let e2e = EndToEndSessionTests()
        runTest("bias and jitter recovery") { e2e.biasAndJitterRecovery() }
        runTest("drift detection") { e2e.driftDetection() }

        suite("StreamingWaveWriter")
        runTest("incremental write == WaveFile read") {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("rc-stream-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: url) }
            let writer = try StreamingWaveWriter(url: url, sampleRate: 48000)
            var expected: [Float] = []
            for chunkIndex in 0..<50 {
                let chunk = (0..<377).map { Float($0 + chunkIndex) / 1000 }
                expected.append(contentsOf: chunk)
                try writer.append(chunk)
            }
            try writer.finalize()
            let (read, sr) = try WaveFile.read(from: url)
            expect(sr == 48000)
            expect(read.count == expected.count)
            expect(zip(read, expected).allSatisfy { $0 == $1 })
        }

        suite("SPSCFloatRing")
        let ring = SPSCFloatRingTests()
        runTest("wrap-around ordering") { ring.wrapAround() }
        runTest("overflow drops, never blocks") { ring.overflow() }
        await runTest("concurrent producer/consumer") { await ring.concurrent() }

        suite("Waveform")
        let waveform = WaveformTests()
        runTest("pyramid exact on bucket boundaries") { waveform.pyramidExactOnBucketBoundaries() }
        runTest("pyramid conservative on arbitrary ranges") { waveform.pyramidConservative() }
        runTest("level selection") { waveform.levelSelection() }
        runTest("columnMinMax raw/pyramid/tail") { waveform.columnMinMax() }
        runTest("viewport round trip, zoom anchor, clamps") { waveform.viewportRoundTripAndZoom() }
        runTest("viewport follow anchoring") { waveform.viewportFollow() }
        runTest("grid mapping in WAV domain") { waveform.gridMapping() }
        runTest("hit deviation invariant") { waveform.hitDeviationInvariant() }
        runTest("WaveformData load round trip") { try waveform.loadRoundTrip() }

        finishTests()
    }
}
