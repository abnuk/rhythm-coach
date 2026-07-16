import Foundation

/// Reported latency of one direction (input or output) in samples,
/// summed from CoreAudio properties:
/// device latency + safety offset + stream latency + buffer frames.
public struct ReportedLatency: Codable, Sendable, Equatable {
    public var deviceLatency: Int
    public var safetyOffset: Int
    public var streamLatency: Int
    public var bufferFrames: Int

    public var totalSamples: Int {
        deviceLatency + safetyOffset + streamLatency + bufferFrames
    }

    public init(deviceLatency: Int = 0, safetyOffset: Int = 0, streamLatency: Int = 0, bufferFrames: Int = 0) {
        self.deviceLatency = deviceLatency
        self.safetyOffset = safetyOffset
        self.streamLatency = streamLatency
        self.bufferFrames = bufferFrames
    }
}

/// The complete latency model. Because scoring compares onset time against
/// click time on one shared sample clock, a single net constant matters:
/// the round-trip (output + input) delay between "click scheduled at S" and
/// "its sound observed in the input buffer". A loopback calibration measures
/// exactly that and supersedes the reported sum; a manual driver-error
/// offset (Ableton DEC-style) is always added on top.
public struct LatencyModel: Codable, Sendable, Equatable {
    public var reportedInput: ReportedLatency
    public var reportedOutput: ReportedLatency
    /// Measured round-trip from the loopback test, in samples.
    public var calibratedRoundtripSamples: Double?
    /// Manual driver-error compensation, in ms (may be negative).
    public var manualOffsetMs: Double

    public init(
        reportedInput: ReportedLatency = ReportedLatency(),
        reportedOutput: ReportedLatency = ReportedLatency(),
        calibratedRoundtripSamples: Double? = nil,
        manualOffsetMs: Double = 0
    ) {
        self.reportedInput = reportedInput
        self.reportedOutput = reportedOutput
        self.calibratedRoundtripSamples = calibratedRoundtripSamples
        self.manualOffsetMs = manualOffsetMs
    }

    public var usesCalibration: Bool { calibratedRoundtripSamples != nil }

    public func netCompensationSamples(sampleRate: Double) -> Double {
        let base = calibratedRoundtripSamples
            ?? Double(reportedInput.totalSamples + reportedOutput.totalSamples)
        return base + manualOffsetMs / 1000 * sampleRate
    }

    public func netCompensationMs(sampleRate: Double) -> Double {
        netCompensationSamples(sampleRate: sampleRate) / sampleRate * 1000
    }
}
