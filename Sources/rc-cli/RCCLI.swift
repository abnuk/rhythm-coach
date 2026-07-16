import CoreAudio
import Foundation
import RhythmAudio
import RhythmCore

enum RCCLI {
    static func run(arguments: [String]) {
        guard let command = arguments.first else {
            printUsage()
            return
        }
        let options = parseOptions(Array(arguments.dropFirst()))
        do {
            switch command {
            case "version": print("rc-cli 1.0.0")
            case "devices": try listDevices()
            case "duplex": try duplexSmoke(options)
            case "calibrate": try calibrate(options)
            case "gen-session": try generateSession(options)
            case "analyze": try analyze(options)
            case "selftest": try selfTest(options)
            default:
                print("unknown command: \(command)")
                printUsage()
                exit(2)
            }
        } catch {
            fputs("error: \(error)\n", stderr)
            exit(1)
        }
    }

    static func printUsage() {
        print("""
        rc-cli — RhythmCoach headless audio harness

        usage: rc-cli <command> [options]
          devices                          list audio devices with capabilities
          duplex      [--in ID] [--out ID] [--rate 48000] [--buffer 128]
                      [--seconds 3] [--bpm 120] [--click-gain 0.5]
                      [--monitor-gain 0]      run the duplex engine
          calibrate   [--in ID] [--out ID] [--rate 48000] [--buffer 128]
                                           loopback latency measurement
                                           (loop output to input with a cable)
          gen-session --out FILE [--bpm 100] [--subdivision eighth]
                      [--bias-ms 12] [--jitter-ms 3] [--slots 40]
                      [--latency-samples 600]   synthesize a practice-take WAV
          analyze     --in FILE [--bpm 100] [--subdivision eighth]
                      [--latency-samples 600] [--target-offset-ms 0]
                      [--count-in-bars 1]      detect onsets + score vs grid
          selftest    [--in ID] [--out ID] [--rate 48000] [--buffer 128]
                      [--seconds 10]           calibrate, then loop the app's
                                               own click back and verify the
                                               full pipeline reads 0 ms
        """)
    }

    static func parseOptions(_ args: [String]) -> [String: String] {
        var options: [String: String] = [:]
        var i = 0
        while i < args.count {
            if args[i].hasPrefix("--") {
                let key = String(args[i].dropFirst(2))
                if i + 1 < args.count && !args[i + 1].hasPrefix("--") {
                    options[key] = args[i + 1]
                    i += 2
                } else {
                    options[key] = "true"
                    i += 1
                }
            } else {
                i += 1
            }
        }
        return options
    }

    // MARK: - devices

    static func listDevices() throws {
        let devices = HALDeviceManager.devices()
        let defaultIn = HALDeviceManager.defaultInputDevice()
        let defaultOut = HALDeviceManager.defaultOutputDevice()
        print("ID     In  Out  SR(current)  Buffer(range)      Name")
        for d in devices {
            var marks = ""
            if d.id == defaultIn { marks += " [default in]" }
            if d.id == defaultOut { marks += " [default out]" }
            print(String(
                format: "%-6d %-3d %-3d  %-11.0f  %6d (%d-%d)   %@%@",
                d.id, d.inputChannels, d.outputChannels, d.currentSampleRate,
                d.currentBufferFrames, d.bufferFrameRange.lowerBound, d.bufferFrameRange.upperBound,
                d.name, marks
            ))
        }
    }

    // MARK: - duplex smoke test

    static func duplexSmoke(_ options: [String: String]) throws {
        let engine = try configuredEngine(options)
        let config = engine.config!
        let seconds = Double(options["seconds"] ?? "3") ?? 3
        let bpm = Double(options["bpm"] ?? "120") ?? 120
        let clickGain = Float(options["click-gain"] ?? "0.5") ?? 0.5
        let monitorGain = Float(options["monitor-gain"] ?? "0") ?? 0

        let grid = ClickGrid(
            spec: ClickGridSpec(bpm: bpm, subdivision: .quarter, countInBars: 0),
            sampleRate: config.sampleRate
        )
        print("duplex: device(s) in=\(config.inputDevice) out=\(config.outputDevice) sr=\(config.sampleRate) buffer=\(config.bufferFrames)")
        if let latency = engine.reportedLatency() {
            print("reported latency: input \(latency.input.totalSamples) + output \(latency.output.totalSamples) = \(latency.input.totalSamples + latency.output.totalSamples) samples")
        }

        try engine.start(grid: grid, sound: .woodblock, clickGain: clickGain, monitorGain: monitorGain)
        defer { engine.stop() }
        guard let ctx = engine.context else { throw HALError.unsupported("no context") }

        var inputEnergy: Float = 0
        var inputSamples = 0
        var chunk = [Float](repeating: 0, count: 65536)
        let start = Date()
        var lastCounter: Int64 = 0
        while Date().timeIntervalSince(start) < seconds {
            _ = ctx.dataAvailable.wait(timeout: .now() + 0.5)
            while true {
                let n = chunk.withUnsafeMutableBufferPointer {
                    ctx.ring.read(into: $0.baseAddress!, maxCount: $0.count)
                }
                if n == 0 { break }
                for i in 0..<n { inputEnergy += abs(chunk[i]) }
                inputSamples += n
            }
            lastCounter = ctx.sampleTime
        }

        let expected = seconds * config.sampleRate
        print(String(format: "sample counter advanced to %d (expected ~%.0f)", lastCounter, expected))
        print("input samples received: \(inputSamples), mean |x|: \(inputSamples > 0 ? inputEnergy / Float(inputSamples) : 0)")
        print("ring drops: \(ctx.ring.droppedSamples), overloads: \(ctx.overloadCount)")
        let healthy = Double(lastCounter) > expected * 0.8 && inputSamples > Int(expected * 0.8)
        print(healthy ? "OK: callbacks ticking, shared clock advancing" : "WARN: callbacks or input not flowing as expected")
        if !healthy { exit(1) }
    }

    // MARK: - calibrate

    static func calibrate(_ options: [String: String]) throws {
        let engine = try configuredEngine(options)
        if let latency = engine.reportedLatency() {
            let total = latency.input.totalSamples + latency.output.totalSamples
            print("reported round-trip: \(total) samples (\(String(format: "%.2f", Double(total) / engine.config!.sampleRate * 1000)) ms)")
        }
        print("measuring loopback (connect output to input with a cable)...")
        let result = try LoopbackCalibrator.measure(engine: engine)
        print(String(
            format: "measured round-trip: %.1f samples = %.2f ms (sd %.2f samples, %d clicks)",
            result.roundtripSamples, result.roundtripMs, result.sdSamples, result.runs
        ))
    }

    // MARK: - gen-session / analyze (offline, uses synthesized audio)

    static func gridFromOptions(_ options: [String: String], sampleRate: Double) -> ClickGrid {
        let bpm = Double(options["bpm"] ?? "100") ?? 100
        let subdivision = Subdivision(rawValue: options["subdivision"] ?? "eighth") ?? .eighth
        let countIn = Int(options["count-in-bars"] ?? "1") ?? 1
        let targetOffset = Double(options["target-offset-ms"] ?? "0") ?? 0
        let spec = ClickGridSpec(bpm: bpm, subdivision: subdivision, countInBars: countIn,
                                 targetOffsetMs: targetOffset)
        return ClickGrid(spec: spec, sampleRate: sampleRate)
    }

    /// Synthesizes a "recorded practice take": Karplus-Strong plucks placed
    /// against the grid with a configurable bias, jitter and latency shift.
    static func generateSession(_ options: [String: String]) throws {
        guard let path = options["out"] else { throw HALError.unsupported("--out FILE required") }
        let sampleRate = 44100.0
        let grid = gridFromOptions(options, sampleRate: sampleRate)
        let biasMs = Double(options["bias-ms"] ?? "12") ?? 12
        let jitterMs = Double(options["jitter-ms"] ?? "3") ?? 3
        let slots = Int(options["slots"] ?? "40") ?? 40
        let latencySamples = Double(options["latency-samples"] ?? "600") ?? 600

        let playedSlots = grid.countInSlots..<(grid.countInSlots + slots)
        let totalSamples = Int(grid.sampleTime(ofSlot: playedSlots.upperBound)) + Int(sampleRate)
        var signal = [Float](repeating: 0, count: totalSamples)

        var seed: UInt64 = 0x2545F4914F6CDD1D
        func nextRandom() -> Double {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return Double(seed % 2000) / 1000.0 - 1.0
        }

        let frequencies: [Double] = [82.41, 110.0, 146.83, 196.0]
        for (k, slot) in playedSlots.enumerated() {
            let deviationMs = biasMs + nextRandom() * jitterMs
            let position = grid.sampleTime(ofSlot: slot) + deviationMs / 1000 * sampleRate + latencySamples
            let note = pluck(frequency: frequencies[k % 4], duration: 0.25,
                             sampleRate: sampleRate, amplitude: 0.4, seed: UInt64(k + 1))
            mix(note, into: &signal, at: Int(position.rounded()))
        }
        try WaveFile.write(samples: signal, sampleRate: sampleRate, to: URL(fileURLWithPath: path))
        print("wrote \(path): \(slots) hits, bias \(biasMs) ms, jitter ±\(jitterMs) ms, latency \(latencySamples) samples")
        print("analyze with: rc-cli analyze --in \(path) --bpm \(grid.spec.bpm) --subdivision \(grid.spec.subdivision.rawValue) --latency-samples \(latencySamples)")
    }

    static func analyze(_ options: [String: String]) throws {
        guard let path = options["in"] else { throw HALError.unsupported("--in FILE required") }
        let (samples, sampleRate) = try WaveFile.read(from: URL(fileURLWithPath: path))
        let grid = gridFromOptions(options, sampleRate: sampleRate)
        let latencySamples = Double(options["latency-samples"] ?? "0") ?? 0

        let detector = OnsetDetector(sampleRate: sampleRate)
        let scorer = TimingScorer(grid: grid, latencyCompensationSamples: latencySamples)
        let stats = StatsAccumulator(toleranceMs: 15, sampleRate: sampleRate)

        let onsets = detector.detect(in: samples)
        var lastOnset = 0.0
        for onset in onsets {
            for event in scorer.onOnset(onset) { stats.add(event) }
            lastOnset = onset.sampleTime
        }
        for event in scorer.advance(to: lastOnset) { stats.add(event) }

        let s = stats.snapshot()
        let beatMs = grid.samplesPerBeat / sampleRate * 1000
        print("""
        \(path): \(String(format: "%.1f", Double(samples.count) / sampleRate)) s @ \(Int(sampleRate)) Hz
        grid: \(grid.spec.bpm) BPM \(grid.spec.subdivision.displayName), latency comp \(latencySamples) samples
        onsets detected: \(onsets.count)
        hits: \(s.hitCount)  missed: \(s.missedCount)  extra: \(s.extraCount)

        mean (bias):  \(String(format: "%+.2f ms  (%+.1f%% of beat)", s.meanMs, s.meanMs / beatMs * 100))
        sd (stability): \(String(format: "%.2f ms  (%.1f%% of beat)", s.sdMs, s.sdMs / beatMs * 100))
        min/max:      \(String(format: "%+.2f / %+.2f ms", s.minMs, s.maxMs))
        in ±15 ms:    \(String(format: "%.0f%%", s.pctInTolerance))
        drift:        \(String(format: "%+.2f ms/min", s.driftMsPerMin))
        lag-1 autocorr: \(String(format: "%+.2f", s.lag1))
        """)
    }

    // MARK: - selftest

    /// End-to-end verification on real audio hardware (or a virtual loopback
    /// device): measure the round-trip constant, then play the metronome
    /// with output looped to input — every click must score 0 ms after
    /// compensation. This validates engine, clock, detector, scorer and
    /// stats as one system.
    static func selfTest(_ options: [String: String]) throws {
        let engine = try configuredEngine(options)
        let config = engine.config!
        let seconds = Double(options["seconds"] ?? "10") ?? 10

        print("step 1: loopback calibration")
        let calibration = try LoopbackCalibrator.measure(engine: engine)
        print(String(format: "  round-trip: %.1f samples = %.2f ms (sd %.2f)",
                     calibration.roundtripSamples, calibration.roundtripMs, calibration.sdSamples))

        print("step 2: click through loopback, scored with compensation")
        let spec = ClickGridSpec(bpm: 120, subdivision: .quarter, beatsPerBar: 4,
                                 accentDownbeat: false, countInBars: 1)
        let grid = ClickGrid(spec: spec, sampleRate: config.sampleRate)
        try engine.start(grid: grid, sound: .woodblock, clickGain: 0.9, monitorGain: 0)
        defer { engine.stop() }
        guard let ctx = engine.context else { throw HALError.unsupported("no context") }

        let detector = OnsetDetector(sampleRate: config.sampleRate)
        let scorer = TimingScorer(grid: grid, latencyCompensationSamples: calibration.roundtripSamples)
        let stats = StatsAccumulator(toleranceMs: 2, sampleRate: config.sampleRate)

        var chunk = [Float](repeating: 0, count: 32768)
        var consumed: Int64 = 0
        let targetSamples = Int64(seconds * config.sampleRate)
        let deadline = Date().addingTimeInterval(seconds + 10)
        while consumed < targetSamples && Date() < deadline {
            _ = ctx.dataAvailable.wait(timeout: .now() + 0.5)
            while true {
                let n = chunk.withUnsafeMutableBufferPointer {
                    ctx.ring.read(into: $0.baseAddress!, maxCount: $0.count)
                }
                guard n > 0 else { break }
                consumed += Int64(n)
                chunk.withUnsafeBufferPointer { buf in
                    detector.process(UnsafeBufferPointer(rebasing: buf[0..<n])) { onset in
                        for event in scorer.onOnset(onset) { stats.add(event) }
                    }
                }
            }
        }
        engine.stop()

        let s = stats.snapshot()
        let expectedClicks = Int(seconds * config.sampleRate / grid.samplesPerSlot) - grid.countInSlots
        print(String(format: "  clicks scored: %d (expected ~%d)", s.hitCount, expectedClicks))
        print(String(format: "  mean %+.3f ms · sd %.3f ms · min %+.2f · max %+.2f · in ±2 ms: %.0f%%",
                     s.meanMs, s.sdMs, s.minMs, s.maxMs, s.pctInTolerance))

        let pass = s.hitCount >= expectedClicks - 2
            && abs(s.meanMs) <= 2.0
            && s.sdMs <= 2.0
            && s.pctInTolerance >= 90
        print(pass ? "SELFTEST PASS" : "SELFTEST FAIL")
        if !pass { exit(1) }
    }

    // MARK: - engine setup

    static func configuredEngine(_ options: [String: String]) throws -> DuplexEngine {
        guard let inputDevice = options["in"].flatMap({ AudioDeviceID($0) }) ?? HALDeviceManager.defaultInputDevice() else {
            throw HALError.unsupported("no input device (use --in ID)")
        }
        guard let outputDevice = options["out"].flatMap({ AudioDeviceID($0) }) ?? HALDeviceManager.defaultOutputDevice() else {
            throw HALError.unsupported("no output device (use --out ID)")
        }
        let sampleRate = Double(options["rate"] ?? "48000") ?? 48000
        let buffer = Int(options["buffer"] ?? "128") ?? 128
        let channel = Int(options["channel"] ?? "0") ?? 0

        let engine = DuplexEngine()
        try engine.configure(DuplexEngine.EngineConfig(
            inputDevice: inputDevice,
            outputDevice: outputDevice,
            sampleRate: sampleRate,
            bufferFrames: buffer,
            inputChannel: channel
        ))
        return engine
    }

    // MARK: - local synthesis (mirror of the test-suite generator)

    static func pluck(frequency: Double, duration: Double, sampleRate: Double,
                      amplitude: Float, seed: UInt64) -> [Float] {
        let n = Int(duration * sampleRate)
        let period = max(2, Int(sampleRate / frequency))
        var state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
        var out = [Float](repeating: 0, count: n)
        for i in 0..<min(period, n) {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            out[i] = (Float(state % 2000) / 1000 - 1) * amplitude
        }
        if n > period + 1 {
            for i in (period + 1)..<n {
                out[i] = 0.996 * 0.5 * (out[i - period] + out[i - period - 1])
            }
        }
        let fade = min(Int(0.03 * sampleRate), n)
        for i in 0..<fade {
            let x = Double(i) / Double(fade)
            out[n - 1 - i] *= Float(0.5 - 0.5 * cos(.pi * x))
        }
        return out
    }

    static func mix(_ event: [Float], into buffer: inout [Float], at position: Int) {
        for i in 0..<event.count {
            let j = position + i
            if j >= 0 && j < buffer.count { buffer[j] += event[i] }
        }
    }
}
