import Foundation
import RhythmCore

/// SessionAudioCodec turns a finished take WAV into two AAC .m4a files
/// (input, input + offline-rendered click). These tests pin down the two
/// assumptions the feature rests on: AAC priming/edit-list handling keeps
/// decode sample-aligned, and the click lands exactly at
/// slot time + compensation offset. Correlation is used instead of energy
/// thresholds because AAC pre-echo smears energy up to a transform block.
@MainActor
struct SessionAudioCodecTests {
    private let sampleRate = 48000.0

    private func tempURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-codec-\(UUID().uuidString).\(ext)")
    }

    private func silentGrid() -> ClickGrid {
        ClickGrid(
            spec: ClickGridSpec(bpm: 120, subdivision: .quarter, accentDownbeat: false, countInBars: 0),
            sampleRate: sampleRate
        )
    }

    private func correlation(_ a: ArraySlice<Float>, _ b: ArraySlice<Float>) -> Double {
        var dot = 0.0, normA = 0.0, normB = 0.0
        for (x, y) in zip(a, b) {
            dot += Double(x) * Double(y)
            normA += Double(x) * Double(x)
            normB += Double(y) * Double(y)
        }
        let denom = (normA * normB).squareRoot()
        return denom > 0 ? dot / denom : 0
    }

    /// AAC roundtrip: decoded length matches written length and a transient
    /// stays where it was written (edit-list/priming handled by AVAudioFile).
    func aacRoundtrip() throws {
        let wav = tempURL("wav")
        let inputM4A = tempURL("m4a")
        let mixM4A = tempURL("m4a")
        defer { for url in [wav, inputM4A, mixM4A] { try? FileManager.default.removeItem(at: url) } }

        let total = Int(sampleRate * 5)
        var signal = [Float](repeating: 0, count: total)
        let burstStart = Int(sampleRate * 1.25)
        var template = [Float]()
        for i in 0..<480 {
            let envelope = exp(-Double(i) / 200)
            let value = Float(sin(2 * .pi * 2000 * Double(i) / sampleRate) * envelope * 0.8)
            template.append(value)
            signal[burstStart + i] = value
        }
        try WaveFile.write(samples: signal, sampleRate: sampleRate, to: wav)

        _ = try SessionAudioCodec.encodeSession(
            sourceWAV: wav, inputDestination: inputM4A, mixDestination: mixM4A,
            grid: silentGrid(), sound: .beep, clickGain: 0, clickOffsetSamples: 0
        )

        let (decoded, decodedRate) = try SessionAudioCodec.readMono(url: inputM4A)
        expect(decodedRate == sampleRate, "rate \(decodedRate)")
        expect(abs(decoded.count - total) <= 1, "length \(decoded.count) vs \(total)")

        let pad = 2000
        let window = Array(decoded[(burstStart - pad)..<(burstStart + template.count + pad)])
        let lag = CrossCorrelator.bestLag(signal: window, template: template)
        expect(lag != nil && abs(lag! - Double(pad)) <= 2, "burst at lag \(String(describing: lag))")
    }

    /// The mix places each click at slot time + clickOffsetSamples.
    func clickPlacement() throws {
        let wav = tempURL("wav")
        let inputM4A = tempURL("m4a")
        let mixM4A = tempURL("m4a")
        defer { for url in [wav, inputM4A, mixM4A] { try? FileManager.default.removeItem(at: url) } }

        let total = Int(sampleRate * 4)
        try WaveFile.write(samples: [Float](repeating: 0, count: total), sampleRate: sampleRate, to: wav)

        let offsetSamples = 480.0
        _ = try SessionAudioCodec.encodeSession(
            sourceWAV: wav, inputDestination: inputM4A, mixDestination: mixM4A,
            grid: silentGrid(), sound: .beep, clickGain: 0.8, clickOffsetSamples: offsetSamples
        )

        let (mix, _) = try SessionAudioCodec.readMono(url: mixM4A)
        // accentDownbeat off + quarter grid: every click is the beat sound.
        let template = ClickSoundSynth.make(sound: .beep, sampleRate: sampleRate).beat
        let samplesPerBeat = Int(sampleRate * 60 / 120)
        for beat in 1...3 {
            let expected = beat * samplesPerBeat + Int(offsetSamples)
            let pad = 2000
            let window = Array(mix[(expected - pad)..<(expected + template.count + pad)])
            let lag = CrossCorrelator.bestLag(signal: window, template: template)
            expect(lag != nil && abs(lag! - Double(pad)) <= 2,
                   "beat \(beat) at lag \(String(describing: lag))")
        }
    }

    /// Mix length equals input length; away from clicks the mix is the input,
    /// at a click it isn't.
    func mixEqualsInputPlusClick() throws {
        let wav = tempURL("wav")
        let inputM4A = tempURL("m4a")
        let mixM4A = tempURL("m4a")
        defer { for url in [wav, inputM4A, mixM4A] { try? FileManager.default.removeItem(at: url) } }

        let total = Int(sampleRate * 3)
        let sine = (0..<total).map { Float(sin(2 * .pi * 220 * Double($0) / sampleRate) * 0.3) }
        try WaveFile.write(samples: sine, sampleRate: sampleRate, to: wav)

        _ = try SessionAudioCodec.encodeSession(
            sourceWAV: wav, inputDestination: inputM4A, mixDestination: mixM4A,
            grid: silentGrid(), sound: .beep, clickGain: 0.5, clickOffsetSamples: 0
        )

        let (input, _) = try SessionAudioCodec.readMono(url: inputM4A)
        let (mix, _) = try SessionAudioCodec.readMono(url: mixM4A)
        expect(abs(input.count - mix.count) <= 1, "lengths \(input.count) vs \(mix.count)")

        // Between beats (24000 apart) both decodes carry only the sine.
        let clean = 30000..<44000
        expect(correlation(mix[clean], input[clean]) > 0.99, "clean segment differs")

        // Right at a beat the click must be present in the mix only.
        let clickRange = 24000..<25000
        let difference = zip(mix[clickRange], input[clickRange])
            .reduce(0.0) { $0 + Double(($1.0 - $1.1) * ($1.0 - $1.1)) }
        expect((difference / 1000).squareRoot() > 0.05, "click missing from mix")
    }

    /// WaveformData.load dispatches by extension: m4a decodes via the codec,
    /// wav stays on the legacy reader.
    func waveformLoadDispatch() throws {
        let wav = tempURL("wav")
        let inputM4A = tempURL("m4a")
        let mixM4A = tempURL("m4a")
        defer { for url in [wav, inputM4A, mixM4A] { try? FileManager.default.removeItem(at: url) } }

        let total = Int(sampleRate)
        let sine = (0..<total).map { Float(sin(2 * .pi * 440 * Double($0) / sampleRate) * 0.5) }
        try WaveFile.write(samples: sine, sampleRate: sampleRate, to: wav)
        _ = try SessionAudioCodec.encodeSession(
            sourceWAV: wav, inputDestination: inputM4A, mixDestination: mixM4A,
            grid: silentGrid(), sound: .beep, clickGain: 0, clickOffsetSamples: 0
        )

        let fromM4A = try WaveformData.load(url: inputM4A)
        expect(fromM4A.sampleRate == sampleRate)
        expect(abs(fromM4A.samples.count - total) <= 1)

        let fromWAV = try WaveformData.load(url: wav)
        expect(fromWAV.samples.count == total)
    }

    /// A failing encode deletes its partial outputs (only the WAV survives).
    func encodeFailureCleanup() throws {
        let wav = tempURL("wav")
        let inputM4A = tempURL("m4a")
        let badMix = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-codec-missing-\(UUID().uuidString)")
            .appendingPathComponent("mix.m4a")
        defer {
            try? FileManager.default.removeItem(at: wav)
            try? FileManager.default.removeItem(at: inputM4A)
        }

        try WaveFile.write(samples: [Float](repeating: 0, count: 4800), sampleRate: sampleRate, to: wav)

        var thrown = false
        do {
            _ = try SessionAudioCodec.encodeSession(
                sourceWAV: wav, inputDestination: inputM4A, mixDestination: badMix,
                grid: silentGrid(), sound: .beep, clickGain: 0.5, clickOffsetSamples: 0
            )
        } catch {
            thrown = true
        }
        expect(thrown, "expected encode into a missing directory to throw")
        expect(!FileManager.default.fileExists(atPath: inputM4A.path), "partial input .m4a left behind")
        expect(FileManager.default.fileExists(atPath: wav.path), "source WAV must survive")
    }
}
