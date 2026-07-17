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
            refreshLatencyInfo()
            restartIdleMonitoringIfActive()
        }
    }
    var outputDeviceID: AudioDeviceID? {
        didSet {
            UserDefaults.standard.set(outputDeviceUID, forKey: "outputUID")
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
        didSet { restartIdleMonitoringIfActive() }
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
    var toleranceMs: Double = 15
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

    private let engine = DuplexEngine()
    private var pipeline: AnalysisPipeline?
    private var pollTask: Task<Void, Never>?
    private var currentGrid: ClickGrid?
    private var latencySource = "reported"
    private var isMonitoringIdle = false

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
        refreshLatencyInfo()
    }

    var inputDevice: AudioDeviceInfo? { devices.first { $0.id == inputDeviceID } }
    var outputDevice: AudioDeviceInfo? { devices.first { $0.id == outputDeviceID } }
    var inputDeviceUID: String? { inputDevice?.uid }
    var outputDeviceUID: String? { outputDevice?.uid }

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
            sampleRate: sampleRate, bufferFrames: bufferFrames
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
                inputChannel: inputChannel
            ))
            refreshLatencyInfo()

            let grid = ClickGrid(spec: gridSpec(), sampleRate: sampleRate)
            currentGrid = grid
            let model = latencyModel
            latencySource = model.usesCalibration ? "calibrated" : "reported"

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
            lastSession = record
            lastSessionHits = result.hits
        } else if let url = result.recordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        sessionStart = nil
        // Resume standalone monitoring if the user keeps it enabled.
        updateIdleMonitoring()
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
                inputChannel: inputChannel
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
            inputChannel: inputChannel
        )
        let inputUID = inputDeviceUID ?? ""
        let outputUID = outputDeviceUID ?? ""
        let buffer = bufferFrames

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
                        bufferFrames: buffer, result: result
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
