import Foundation
import RhythmCore

@MainActor struct OnsetDetectorTests {
    let sampleRate = 44100.0

    /// Asserts detected onsets match expectations pairwise within tolerance.
    func assertOnsets(_ detected: [Onset], expectedSamples: [Int], toleranceMs: Double,
                      file: StaticString = #filePath, line: UInt = #line) {
        expect(detected.count == expectedSamples.count,
                "expected \(expectedSamples.count) onsets, got \(detected.count): \(detected.map(\.sampleTime))",
                file: file, line: line)
        guard detected.count == expectedSamples.count else { return }
        let toleranceSamples = toleranceMs / 1000 * sampleRate
        for (onset, expected) in zip(detected, expectedSamples) {
            let error = onset.sampleTime - Double(expected)
            expect(abs(error) <= toleranceSamples,
                    "onset at \(onset.sampleTime) vs expected \(expected): error \(error / sampleRate * 1000) ms",
                    file: file, line: line)
        }
    }

    func clickBursts() {
        var signal = [Float](repeating: 0, count: Int(sampleRate * 4))
        let positions = [11025, 33075, 55125, 77175, 99225, 121275, 143325]
        let burst = SignalGenerator.clickBurst(sampleRate: sampleRate)
        for p in positions { SignalGenerator.mix(burst, into: &signal, at: p) }

        let detector = OnsetDetector(sampleRate: sampleRate)
        assertOnsets(detector.detect(in: signal), expectedSamples: positions, toleranceMs: 3)
    }

    func singlePlucks() {
        var signal = [Float](repeating: 0, count: Int(sampleRate * 5))
        let interval = Int(0.4 * sampleRate)
        let frequencies: [Double] = [82.41, 110, 146.83, 196, 246.94, 329.63, 110, 196, 82.41, 146.83]
        var positions: [Int] = []
        for (k, f) in frequencies.enumerated() {
            let p = 8000 + k * interval
            positions.append(p)
            let note = SignalGenerator.pluck(frequency: f, duration: 0.35, sampleRate: sampleRate, seed: UInt64(k + 1))
            SignalGenerator.mix(note, into: &signal, at: p)
        }

        let detector = OnsetDetector(sampleRate: sampleRate)
        assertOnsets(detector.detect(in: signal), expectedSamples: positions, toleranceMs: 3)
    }

    func chordStrums() {
        var signal = [Float](repeating: 0, count: Int(sampleRate * 5))
        let interval = Int(0.5 * sampleRate)
        var positions: [Int] = []
        for k in 0..<8 {
            let p = 10000 + k * interval
            positions.append(p)
            let chord = SignalGenerator.strum(frequencies: SignalGenerator.eMajor, spreadMs: 15,
                                              duration: 0.4, sampleRate: sampleRate, seed: UInt64(k * 11 + 3))
            SignalGenerator.mix(chord, into: &signal, at: p)
        }

        let detector = OnsetDetector(sampleRate: sampleRate)
        let detected = detector.detect(in: signal)
        expect(detected.count == positions.count,
                "one onset per strum expected, got \(detected.count)")
        guard detected.count == positions.count else { return }
        for (onset, expected) in zip(detected, positions) {
            let errorMs = (onset.sampleTime - Double(expected)) / sampleRate * 1000
            // The strum spreads string attacks over 15 ms; the detected onset
            // must sit inside a small window around that spread.
            expect(errorMs >= -3 && errorMs <= 18, "strum onset error \(errorMs) ms")
        }
    }

    func minIOIMerging() {
        var signal = [Float](repeating: 0, count: Int(sampleRate * 2))
        let first = 22050
        let second = first + Int(0.025 * sampleRate)
        let note = SignalGenerator.pluck(frequency: 196, duration: 0.3, sampleRate: sampleRate)
        SignalGenerator.mix(note, into: &signal, at: first)
        SignalGenerator.mix(note, into: &signal, at: second)

        let detector = OnsetDetector(sampleRate: sampleRate)
        let detected = detector.detect(in: signal)
        expect(detected.count == 1, "expected merged event, got \(detected.map(\.sampleTime))")
    }

    func noiseFloorSilence() {
        var signal = [Float](repeating: 0, count: Int(sampleRate * 4))
        SignalGenerator.addNoiseFloor(&signal, amplitudeDb: -60)

        let detector = OnsetDetector(sampleRate: sampleRate)
        expect(detector.detect(in: signal).isEmpty)
    }

    func quietAfterLoud() {
        var signal = [Float](repeating: 0, count: Int(sampleRate * 3))
        SignalGenerator.addNoiseFloor(&signal, amplitudeDb: -66)
        let loud = SignalGenerator.strum(frequencies: SignalGenerator.eMajor, spreadMs: 10,
                                         duration: 0.3, sampleRate: sampleRate, amplitude: 0.5)
        let quiet = SignalGenerator.pluck(frequency: 146.83, duration: 0.2, sampleRate: sampleRate,
                                          amplitude: 0.06, damping: 0.99)
        let positions = [11025, Int(0.6 * sampleRate), Int(1.2 * sampleRate), Int(1.8 * sampleRate)]
        SignalGenerator.mix(loud, into: &signal, at: positions[0])
        SignalGenerator.mix(quiet, into: &signal, at: positions[1])
        SignalGenerator.mix(loud, into: &signal, at: positions[2])
        SignalGenerator.mix(quiet, into: &signal, at: positions[3])

        let detector = OnsetDetector(sampleRate: sampleRate)
        assertOnsets(detector.detect(in: signal), expectedSamples: positions, toleranceMs: 5)
    }

    func streamingEquivalence() {
        var signal = [Float](repeating: 0, count: Int(sampleRate * 3))
        let positions = [9000, 30000, 60000, 95000, 120000]
        for (k, p) in positions.enumerated() {
            let note = SignalGenerator.pluck(frequency: 164.81, duration: 0.3,
                                             sampleRate: sampleRate, seed: UInt64(k + 5))
            SignalGenerator.mix(note, into: &signal, at: p)
        }

        let offline = OnsetDetector(sampleRate: sampleRate).detect(in: signal)

        let streaming = OnsetDetector(sampleRate: sampleRate)
        var streamed: [Onset] = []
        var index = 0
        let chunk = 64  // small audio-buffer-sized chunks
        while index < signal.count {
            let end = min(index + chunk, signal.count)
            Array(signal[index..<end]).withUnsafeBufferPointer { buf in
                streaming.process(buf) { streamed.append($0) }
            }
            index = end
        }
        streaming.flush { streamed.append($0) }

        expect(streamed.count == offline.count)
        for (a, b) in zip(streamed, offline) {
            expect(abs(a.sampleTime - b.sampleTime) < 1.0)
        }
    }

    func wavRoundtrip() throws {
        var signal = [Float](repeating: 0, count: Int(sampleRate * 2))
        let positions = [15000, 45000, 70000]
        for p in positions {
            let note = SignalGenerator.pluck(frequency: 110, duration: 0.3, sampleRate: sampleRate)
            SignalGenerator.mix(note, into: &signal, at: p)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rhythmcoach-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try WaveFile.write(samples: signal, sampleRate: sampleRate, to: url)
        let (read, sr) = try WaveFile.read(from: url)
        expect(sr == sampleRate)
        expect(read.count == signal.count)

        let detector = OnsetDetector(sampleRate: sr)
        assertOnsets(detector.detect(in: read), expectedSamples: positions, toleranceMs: 3)
    }
}
