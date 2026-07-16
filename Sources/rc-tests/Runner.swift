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
        runTest("streaming == offline") { onset.streamingEquivalence() }
        runTest("WAV roundtrip") { try onset.wavRoundtrip() }

        suite("ClickGrid")
        let grid = ClickGridTests()
        runTest("slot spacing exact") { grid.slotSpacing() }
        runTest("slot kinds") { grid.slotKinds() }
        runTest("gap pattern") { grid.gapPattern() }
        runTest("triplets") { grid.triplets() }

        suite("TimingScorer")
        let scorer = TimingScorerTests()
        runTest("exact deviations, count-in ignored") { scorer.exactDeviations() }
        runTest("latency compensation") { scorer.compensation() }
        runTest("target offset mode") { scorer.targetOffset() }
        runTest("slot contention") { scorer.slotContention() }
        runTest("extra and missed") { scorer.extraAndMissed() }

        suite("Stats")
        let stats = StatsTests()
        runTest("moments closed-form") { stats.basicMoments() }
        runTest("drift ramp") { stats.driftRamp() }
        runTest("lag-1 alternating") { stats.lag1Alternating() }
        runTest("histogram bins") { stats.histogramBins() }
        runTest("missed/extra counting") { stats.missedExtra() }

        suite("LatencyModel")
        runTest("compensation priority") { LatencyModelTests().compensationPriority() }

        suite("CrossCorrelator")
        runTest("template location in noise") { CrossCorrelatorTests().templateLocation() }

        suite("ClickRenderer")
        let renderer = ClickRendererTests()
        runTest("sample accuracy across callbacks") { renderer.sampleAccuracy() }
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

        finishTests()
    }
}
