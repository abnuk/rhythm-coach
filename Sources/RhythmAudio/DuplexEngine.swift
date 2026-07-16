import CoreAudio
import Foundation
import RhythmCore

/// Full-duplex CoreAudio engine on a single device: when the chosen input
/// and output are different physical devices, a private aggregate (with
/// drift compensation, clocked by the output) is created so one IOProc
/// still sees both directions on one sample clock.
public final class DuplexEngine {
    public struct EngineConfig: Sendable {
        public var inputDevice: AudioDeviceID
        public var outputDevice: AudioDeviceID
        public var sampleRate: Double
        public var bufferFrames: Int
        public var inputChannel: Int

        public init(inputDevice: AudioDeviceID, outputDevice: AudioDeviceID,
                    sampleRate: Double, bufferFrames: Int, inputChannel: Int = 0) {
            self.inputDevice = inputDevice
            self.outputDevice = outputDevice
            self.sampleRate = sampleRate
            self.bufferFrames = bufferFrames
            self.inputChannel = inputChannel
        }
    }

    public private(set) var config: EngineConfig?
    public private(set) var context: RealtimeContext?

    private var ioDevice: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var procID: AudioDeviceIOProcID?
    private var running = false

    public init() {}

    deinit {
        stop()
        destroyAggregate()
    }

    /// Applies device configuration (sample rate on both devices, aggregate
    /// creation if needed, buffer size on the IO device).
    public func configure(_ config: EngineConfig) throws {
        stop()
        destroyAggregate()

        try HALDeviceManager.setNominalSampleRate(config.sampleRate, on: config.inputDevice)
        if config.outputDevice != config.inputDevice {
            try HALDeviceManager.setNominalSampleRate(config.sampleRate, on: config.outputDevice)
        }

        if config.inputDevice == config.outputDevice {
            ioDevice = config.inputDevice
        } else {
            aggregateID = try Self.createPrivateAggregate(
                input: config.inputDevice, output: config.outputDevice
            )
            ioDevice = aggregateID
            try HALDeviceManager.setNominalSampleRate(config.sampleRate, on: ioDevice)
        }

        let range = HALDeviceManager.info(for: ioDevice)?.bufferFrameRange ?? 32...4096
        let frames = min(max(config.bufferFrames, range.lowerBound), range.upperBound)
        try HALDeviceManager.setBufferFrameSize(frames, on: ioDevice)
        self.config = config
    }

    /// Creates the realtime context and starts the IOProc.
    public func start(grid: ClickGrid, sound: ClickSound, clickGain: Float, monitorGain: Float) throws {
        guard let config else { throw HALError.unsupported("engine not configured") }
        stop()

        let ctx = RealtimeContext(grid: grid, sound: sound, inputChannel: config.inputChannel)
        ctx.setClickGain(clickGain)
        ctx.setMonitorGain(monitorGain)
        self.context = ctx

        var newProc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&newProc, ioDevice, nil) {
            [unowned ctx] now, inputData, inputTime, outputData, outputTime in
            ctx.handleIO(input: inputData, inputTime: inputTime,
                         output: outputData, outputTime: outputTime, now: now)
        }
        try HAL.check(status, "AudioDeviceCreateIOProcIDWithBlock")
        procID = newProc
        try HAL.check(AudioDeviceStart(ioDevice, procID), "AudioDeviceStart")
        running = true
    }

    public func stop() {
        guard running || procID != nil else { return }
        if let procID {
            AudioDeviceStop(ioDevice, procID)
            AudioDeviceDestroyIOProcID(ioDevice, procID)
        }
        procID = nil
        running = false
        // Wake any consumer blocked on the semaphore so it can observe stop.
        context?.dataAvailable.signal()
    }

    private func destroyAggregate() {
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        ioDevice = 0
    }

    /// Reported round-trip latency of the configured pair (input direction
    /// of the input device + output direction of the output device).
    public func reportedLatency() -> (input: ReportedLatency, output: ReportedLatency)? {
        guard let config else { return nil }
        return (
            HALDeviceManager.reportedLatency(of: config.inputDevice, scope: kAudioObjectPropertyScopeInput),
            HALDeviceManager.reportedLatency(of: config.outputDevice, scope: kAudioObjectPropertyScopeOutput)
        )
    }

    // MARK: - Aggregate

    private static func createPrivateAggregate(input: AudioDeviceID, output: AudioDeviceID) throws -> AudioObjectID {
        let inputUID = try HAL.getString(input, HAL.address(kAudioDevicePropertyDeviceUID))
        let outputUID = try HAL.getString(output, HAL.address(kAudioDevicePropertyDeviceUID))

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "RhythmCoach Aggregate",
            kAudioAggregateDeviceUIDKey as String: "com.abnuk.rhythmcoach.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey as String: 1,
            kAudioAggregateDeviceMainSubDeviceKey as String: outputUID,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: outputUID],
                [
                    kAudioSubDeviceUIDKey as String: inputUID,
                    kAudioSubDeviceDriftCompensationKey as String: 1,
                ],
            ],
        ]

        var aggregateID = AudioObjectID(0)
        try HAL.check(
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID),
            "AudioHardwareCreateAggregateDevice"
        )
        // Give the HAL a moment to publish the new device's streams.
        usleep(100_000)
        return aggregateID
    }
}
