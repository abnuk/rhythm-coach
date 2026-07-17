import CoreAudio
import Foundation
import Observation
import RhythmAudio
import RhythmCore
import SwiftUI

/// Central app state: audio configuration, click configuration, session
/// transport, live statistics, calibration and persistence.
@MainActor
@Observable
final class TransportController {
    // MARK: Audio configuration
    var devices: [AudioDeviceInfo] = []
    var inputDeviceID: AudioDeviceID? {
        didSet {
            UserDefaults.standard.set(inputDeviceUID, forKey: "inputUID")
            refreshChannelChoices()
            // Each device remembers its own channel selection (DAW-style);
            // the != guard avoids a redundant idle-monitoring restart.
            let restored = ChannelMapping.clampedInputChannel(
                inputDeviceUID.map { UserDefaults.standard.integer(forKey: "inputChannel.\($0)") } ?? 0,
                channelCount: inputDevice?.inputChannels ?? 1
            )
            if inputChannel != restored { inputChannel = restored }
            refreshLatencyInfo()
            restartIdleMonitoringIfActive()
        }
    }
    var outputDeviceID: AudioDeviceID? {
        didSet {
            UserDefaults.standard.set(outputDeviceUID, forKey: "outputUID")
            refreshChannelChoices()
            let restored = ChannelMapping.clampedPairIndex(
                outputDeviceUID.map { UserDefaults.standard.integer(forKey: "outputPair.\($0)") } ?? 0,
                channelCount: outputDevice?.outputChannels ?? 2
            )
            if outputPair != restored { outputPair = restored }
            refreshLatencyInfo()
            restartIdleMonitoringIfActive()
        }
    }
    var sampleRate: Double = 48000 {
        didSet { refreshLatencyInfo(); restartIdleMonitoringIfActive() }
    }
    var bufferFrames: Int = 128 {
        didSet { refreshLatencyInfo(); restartIdleMonitoringIfActive() }
    }
    var inputChannel: Int = 0 {
        didSet {
            if let uid = inputDeviceUID {
                UserDefaults.standard.set(inputChannel, forKey: "inputChannel.\(uid)")
            }
            refreshLatencyInfo()
            restartIdleMonitoringIfActive()
        }
    }
    /// Stereo-pair index on the output device (0 = channels 1/2).
    var outputPair: Int = 0 {
        didSet {
            if let uid = outputDeviceUID {
                UserDefaults.standard.set(outputPair, forKey: "outputPair.\(uid)")
            }
            refreshLatencyInfo()
            restartIdleMonitoringIfActive()
        }
    }

    // MARK: Click configuration
    var bpm: Double = 90
    var subdivision: Subdivision = .eighth
    var beatsPerBar: Int = 4
    var accentDownbeat = true
    /// What you hear; analysis always tracks every slot of `subdivision`.
    var clickDensity: ClickDensity = .everySlot
    /// Off = playing patterns with rests; empty slots are not "missed".
    var expectEverySlot = true
    var gapClickEnabled = false
    var gapBarsOn = 2
    var gapBarsOff = 2
    var countInBars = 1
    var targetOffsetMs: Double = 0
    var clickSound: ClickSound = .woodblock
    var clickGain: Double = 0.7 {
        didSet { engine.context?.setClickGain(Float(clickGain)) }
    }
    /// Input monitoring works both during a session and standalone: with the
    /// metronome stopped, the duplex engine keeps running in monitor-only
    /// mode (click muted, capture disabled).
    var monitorEnabled = false {
        didSet {
            engine.context?.setMonitorGain(monitorEnabled ? Float(monitorGain) : 0)
            updateIdleMonitoring()
        }
    }
    var monitorGain: Double = 0.8 {
        didSet { engine.context?.setMonitorGain(monitorEnabled ? Float(monitorGain) : 0) }
    }
    /// nil = Custom (manual ms picker).
    var targetLevel: TargetLevel? = TransportController.loadTargetLevel() {
        didSet { UserDefaults.standard.set(targetLevel?.rawValue ?? "custom", forKey: "targetLevel") }
    }
    var customToleranceMs: Double = TransportController.loadCustomToleranceMs() {
        didSet { UserDefaults.standard.set(customToleranceMs, forKey: "customToleranceMs") }
    }
    /// Tolerance snapshotted for the running take — the accumulator is fixed
    /// at start(), so live views must not follow bpm/level changes mid-take.
    private var runToleranceMs: Double?

    var toleranceMs: Double {
        if let runToleranceMs { return runToleranceMs }
        guard let targetLevel else { return customToleranceMs }
        return targetLevel.windowMs(slotIOIMs: TimingRating.slotIOIMs(bpm: bpm, subdivision: subdivision))
    }

    private static func loadTargetLevel() -> TargetLevel? {
        guard let raw = UserDefaults.standard.string(forKey: "targetLevel") else { return .advanced }
        return TargetLevel(rawValue: raw)
    }

    private static func loadCustomToleranceMs() -> Double {
        let stored = UserDefaults.standard.double(forKey: "customToleranceMs")
        return stored > 0 ? stored : 15
    }

    var recordAudio = true

    // MARK: Latency
    var reportedInput = ReportedLatency()
    var reportedOutput = ReportedLatency()
    var calibration: CalibrationResult?
    var manualOffsetMs: Double = UserDefaults.standard.double(forKey: "manualOffsetMs") {
        didSet { UserDefaults.standard.set(manualOffsetMs, forKey: "manualOffsetMs") }
    }
    var isCalibrating = false
    var calibrationMessage: String?

    // MARK: Session state
    var isRunning = false
    var sessionStart: Date?
    var snapshot = LiveStatsSnapshot()
    var liveHits: [Hit] = []
    var lastError: String?
    var finishedSession: SessionRecord?
    /// Last persisted session, kept after the summary sheet is dismissed
    /// (`.sheet(item:)` nils `finishedSession` on dismiss) so the practice
    /// screen can keep showing the take's waveform.
    var lastSession: SessionRecord?
    var lastSessionHits: [Hit] = []
    /// True while a finished take is being encoded to AAC in the background.
    var isEncodingTake = false

    private let engine = DuplexEngine()
    private var pipeline: AnalysisPipeline?
    private var pollTask: Task<Void, Never>?
    private var currentGrid: ClickGrid?
    private var latencySource = "reported"
    private var isMonitoringIdle = false
    // Captured at start() so the offline mix uses exactly what the session
    // (and its scorer) used, even if the user tweaks settings mid-take.
    private var sessionSound: ClickSound = .woodblock
    private var sessionClickGain: Float = 0.7
    private var sessionCompSamples: Double = 0
    /// Guards UI state against an old take's encode finishing after a newer
    /// session already took over.
    private var activeEncodeTakeID: String?

    init() {
        refreshDevices()
    }

    // MARK: - Devices

    func refreshDevices() {
        devices = HALDeviceManager.devices().filter { $0.hasInput || $0.hasOutput }
        let savedInputUID = UserDefaults.standard.string(forKey: "inputUID")
        let savedOutputUID = UserDefaults.standard.string(forKey: "outputUID")
        if inputDeviceID == nil || !devices.contains(where: { $0.id == inputDeviceID }) {
            inputDeviceID = devices.first(where: { $0.uid == savedInputUID && $0.hasInput })?.id
                ?? HALDeviceManager.defaultInputDevice()
        }
        if outputDeviceID == nil || !devices.contains(where: { $0.id == outputDeviceID }) {
            outputDeviceID = devices.first(where: { $0.uid == savedOutputUID && $0.hasOutput })?.id
                ?? HALDeviceManager.defaultOutputDevice()
        }
        refreshChannelChoices()
        refreshLatencyInfo()
    }

    var inputDevice: AudioDeviceInfo? { devices.first { $0.id == inputDeviceID } }
    var outputDevice: AudioDeviceInfo? { devices.first { $0.id == outputDeviceID } }
    var inputDeviceUID: String? { inputDevice?.uid }
    var outputDeviceUID: String? { outputDevice?.uid }

    struct InputChannelChoice: Identifiable, Hashable {
        let index: Int
        let label: String
        var id: Int { index }
    }

    /// Cached per device change: labels may involve HAL string lookups.
    private(set) var inputChannelChoices: [InputChannelChoice] = []
    private(set) var outputPairChoices: [ChannelMapping.OutputPair] = []

    private func refreshChannelChoices() {
        if let device = inputDevice {
            inputChannelChoices = (0..<device.inputChannels).map { index in
                let name = HALDeviceManager.inputChannelName(of: device.id, channel: index)
                return InputChannelChoice(
                    index: index,
                    label: name.map { "Input \(index + 1) — \($0)" } ?? "Input \(index + 1)"
                )
            }
        } else {
            inputChannelChoices = []
        }
        outputPairChoices = ChannelMapping.outputPairs(channelCount: outputDevice?.outputChannels ?? 0)
    }

    var availableSampleRates: [Double] {
        let common: Set<Double> = {
            guard let input = inputDevice, let output = outputDevice else { return [44100, 48000] }
            let inputRates = Set(input.sampleRates)
            let outputRates = Set(output.sampleRates)
            let intersection = inputRates.intersection(outputRates)
            return intersection.isEmpty ? inputRates.union(outputRates) : intersection
        }()
        return common.sorted()
    }

    var availableBufferSizes: [Int] {
        let range = inputDevice?.bufferFrameRange ?? 32...4096
        return [32, 64, 128, 256, 512, 1024].filter { range.contains($0) }
    }

    func refreshLatencyInfo() {
        guard let input = inputDeviceID, let output = outputDeviceID else { return }
        reportedInput = HALDeviceManager.reportedLatency(of: input, scope: kAudioObjectPropertyScopeInput)
        reportedOutput = HALDeviceManager.reportedLatency(of: output, scope: kAudioObjectPropertyScopeOutput)
        calibration = lookupCalibration()
    }

    private func lookupCalibration() -> CalibrationResult? {
        guard let inputUID = inputDeviceUID, let outputUID = outputDeviceUID else { return nil }
        return Database.shared.calibration(
            inputUID: inputUID, outputUID: outputUID,
            sampleRate: sampleRate, bufferFrames: bufferFrames,
            inputChannel: inputChannel, outputPair: outputPair
        )
    }

    var latencyModel: LatencyModel {
        LatencyModel(
            reportedInput: reportedInput,
            reportedOutput: reportedOutput,
            calibratedRoundtripSamples: calibration?.roundtripSamples,
            manualOffsetMs: manualOffsetMs
        )
    }

    // MARK: - Transport

    func gridSpec() -> ClickGridSpec {
        ClickGridSpec(
            bpm: bpm,
            subdivision: subdivision,
            beatsPerBar: beatsPerBar,
            accentDownbeat: accentDownbeat,
            clickDensity: clickDensity,
            gapPattern: gapClickEnabled ? GapPattern(barsOn: gapBarsOn, barsOff: gapBarsOff) : nil,
            countInBars: countInBars,
            targetOffsetMs: targetOffsetMs,
            expectEverySlot: expectEverySlot
        )
    }

    func start() {
        guard !isRunning else { return }
        guard let input = inputDeviceID, let output = outputDeviceID else {
            lastError = "Select input and output devices in Audio Setup"
            return
        }
        stopIdleMonitoring()
        lastError = nil
        finishedSession = nil
        lastSession = nil
        lastSessionHits = []

        do {
            try engine.configure(DuplexEngine.EngineConfig(
                inputDevice: input, outputDevice: output,
                sampleRate: sampleRate, bufferFrames: bufferFrames,
                inputChannel: inputChannel, outputPair: outputPair
            ))
            refreshLatencyInfo()

            let grid = ClickGrid(spec: gridSpec(), sampleRate: sampleRate)
            currentGrid = grid
            runToleranceMs = toleranceMs
            let model = latencyModel
            latencySource = model.usesCalibration ? "calibrated" : "reported"
            sessionSound = clickSound
            sessionClickGain = Float(clickGain)
            sessionCompSamples = model.netCompensationSamples(sampleRate: sampleRate)

            var recordingURL: URL?
            if recordAudio {
                let dir = Database.sessionsDirectory()
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                recordingURL = dir.appendingPathComponent("take-\(stamp).wav")
            }

            try engine.start(grid: grid, sound: clickSound,
                             clickGain: Float(clickGain),
                             monitorGain: monitorEnabled ? Float(monitorGain) : 0)

            let pipeline = AnalysisPipeline(
                context: engine.context!,
                grid: grid,
                latencyCompensationSamples: model.netCompensationSamples(sampleRate: sampleRate),
                toleranceMs: toleranceMs,
                recordingURL: recordingURL
            )
            pipeline.start()
            self.pipeline = pipeline

            snapshot = LiveStatsSnapshot()
            liveHits = []
            sessionStart = Date()
            isRunning = true

            pollTask = Task { [weak self] in
                while let self, self.isRunning, !Task.isCancelled {
                    self.pollPipeline()
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
        } catch {
            lastError = "\(error)"
            runToleranceMs = nil
            engine.stop()
        }
    }

    private func pollPipeline() {
        guard let pipeline else { return }
        snapshot = pipeline.latestSnapshot
        for event in pipeline.takeEvents() {
            if case .hit(let hit) = event {
                liveHits.append(hit)
                if liveHits.count > 2000 { liveHits.removeFirst(500) }
            }
        }
    }

    func stop() {
        guard isRunning, let pipeline, let grid = currentGrid, let started = sessionStart else { return }
        isRunning = false
        pollTask?.cancel()
        engine.stop()
        let result = pipeline.stop()
        self.pipeline = nil

        snapshot = result.snapshot
        let final = result.snapshot
        let duration = Date().timeIntervalSince(started)

        let record = SessionRecord(
            id: UUID().uuidString,
            startedAt: started,
            durationSec: duration,
            bpm: grid.spec.bpm,
            subdivision: grid.spec.subdivision.rawValue,
            clickDensity: grid.spec.clickDensity.rawValue,
            gapPattern: grid.spec.gapPattern.map { "\($0.barsOn)/\($0.barsOff)" },
            targetOffsetMs: grid.spec.targetOffsetMs,
            sampleRate: sampleRate,
            bufferFrames: bufferFrames,
            inputDeviceName: inputDevice?.name ?? "?",
            latencyCompMs: latencyModel.netCompensationMs(sampleRate: sampleRate),
            latencySource: latencySource,
            toleranceMs: toleranceMs,
            targetLevel: targetLevel?.rawValue,
            audioPath: result.recordingURL?.path,
            hitCount: final.hitCount,
            missedCount: final.missedCount,
            extraCount: final.extraCount,
            meanMs: final.meanMs,
            sdMs: final.sdMs,
            minMs: final.minMs,
            maxMs: final.maxMs,
            pctInTolerance: final.pctInTolerance,
            driftMsPerMin: final.driftMsPerMin,
            lag1: final.lag1,
            beatsPerBar: grid.spec.beatsPerBar,
            countInBars: grid.spec.countInBars
        )

        // Only persist sessions with actual playing.
        if final.hitCount > 0 {
            let hitRows = result.hits.map {
                HitRow(slotIndex: $0.slotIndex, deviationMs: $0.deviationMs,
                       onsetSample: $0.onsetSample, kind: "hit")
            }
            Database.shared.save(session: record, hits: hitRows)
            finishedSession = record
            lastSessionHits = result.hits
            if let wavURL = result.recordingURL {
                // The row points at the WAV (truthful: that file exists) until
                // the background encode swaps in the .m4a pair. `lastSession`
                // flips only then, so the waveform view never latches onto the
                // WAV that is about to be deleted.
                beginEncode(record: record, wavURL: wavURL, grid: grid)
            } else {
                lastSession = record
            }
        } else if let url = result.recordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        sessionStart = nil
        runToleranceMs = nil
        // Resume standalone monitoring if the user keeps it enabled.
        updateIdleMonitoring()
    }

    private func beginEncode(record: SessionRecord, wavURL: URL, grid: ClickGrid) {
        isEncodingTake = true
        activeEncodeTakeID = record.id
        let base = wavURL.deletingPathExtension()
        let inputURL = base.appendingPathExtension("m4a")
        let mixURL = base.appendingPathExtension("mix").appendingPathExtension("m4a")
        let (sound, gain, comp) = (sessionSound, sessionClickGain, sessionCompSamples)
        Task.detached(priority: .utility) {
            let outcome = Result {
                try SessionAudioCodec.encodeSession(
                    sourceWAV: wavURL, inputDestination: inputURL, mixDestination: mixURL,
                    grid: grid, sound: sound, clickGain: gain, clickOffsetSamples: comp
                )
            }
            await MainActor.run { [weak self] in
                var updated = record
                if case .success(let encoded) = outcome {
                    try? FileManager.default.removeItem(at: wavURL)
                    updated.audioPath = encoded.inputURL.path
                    updated.clickMixPath = encoded.mixURL.path
                    Database.shared.updateSessionAudio(
                        id: record.id,
                        audioPath: updated.audioPath, clickMixPath: updated.clickMixPath
                    )
                }
                // On failure the WAV stays and the row already points at it.
                guard let self, self.activeEncodeTakeID == record.id else { return }
                self.isEncodingTake = false
                self.activeEncodeTakeID = nil
                self.lastSession = updated
                if self.finishedSession?.id == record.id { self.finishedSession = updated }
            }
        }
    }

    // MARK: - Idle (metronome-stopped) monitoring

    private func updateIdleMonitoring() {
        guard !isRunning, !isCalibrating else { return }
        if monitorEnabled && !isMonitoringIdle {
            startIdleMonitoring()
        } else if !monitorEnabled && isMonitoringIdle {
            stopIdleMonitoring()
        }
    }

    private func startIdleMonitoring() {
        guard let input = inputDeviceID, let output = outputDeviceID else { return }
        do {
            try engine.configure(DuplexEngine.EngineConfig(
                inputDevice: input, outputDevice: output,
                sampleRate: sampleRate, bufferFrames: bufferFrames,
                inputChannel: inputChannel, outputPair: outputPair
            ))
            // Any grid works: the click is muted and capture is off.
            let grid = ClickGrid(
                spec: ClickGridSpec(bpm: 120, subdivision: .quarter, countInBars: 0),
                sampleRate: sampleRate
            )
            try engine.start(grid: grid, sound: clickSound, clickGain: 0,
                             monitorGain: Float(monitorGain))
            engine.context?.setCaptureEnabled(false)
            isMonitoringIdle = true
            lastError = nil
        } catch {
            lastError = "Monitoring failed: \(error)"
            isMonitoringIdle = false
        }
    }

    private func stopIdleMonitoring() {
        guard isMonitoringIdle else { return }
        engine.stop()
        isMonitoringIdle = false
    }

    private func restartIdleMonitoringIfActive() {
        guard isMonitoringIdle else { return }
        stopIdleMonitoring()
        updateIdleMonitoring()
    }

    // MARK: - Calibration

    func runCalibration() {
        guard !isRunning, !isCalibrating else { return }
        guard let input = inputDeviceID, let output = outputDeviceID else {
            calibrationMessage = "Select devices first"
            return
        }
        // Pause standalone monitoring: with a physical loopback cable the
        // input→output passthrough would feed back into the measurement.
        stopIdleMonitoring()
        isCalibrating = true
        calibrationMessage = "Measuring…"

        let config = DuplexEngine.EngineConfig(
            inputDevice: input, outputDevice: output,
            sampleRate: sampleRate, bufferFrames: bufferFrames,
            inputChannel: inputChannel, outputPair: outputPair
        )
        let inputUID = inputDeviceUID ?? ""
        let outputUID = outputDeviceUID ?? ""
        let buffer = bufferFrames
        let channel = inputChannel
        let pair = outputPair

        Task.detached { [weak self] in
            let outcome: Result<CalibrationResult, Error>
            do {
                let engine = DuplexEngine()
                try engine.configure(config)
                let result = try LoopbackCalibrator.measure(engine: engine)
                outcome = .success(result)
            } catch {
                outcome = .failure(error)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isCalibrating = false
                switch outcome {
                case .success(let result):
                    Database.shared.saveCalibration(
                        inputUID: inputUID, outputUID: outputUID,
                        bufferFrames: buffer, inputChannel: channel, outputPair: pair,
                        result: result
                    )
                    self.calibration = result
                    self.calibrationMessage = String(
                        format: "Measured %.2f ms (sd %.2f samples, %d clicks)",
                        result.roundtripMs, result.sdSamples, result.runs
                    )
                case .failure(let error):
                    self.calibrationMessage = "\(error)"
                }
                self.updateIdleMonitoring()
            }
        }
    }
}
