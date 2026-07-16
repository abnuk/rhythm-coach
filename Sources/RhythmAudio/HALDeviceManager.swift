import CoreAudio
import Foundation
import RhythmCore

public struct AudioDeviceInfo: Sendable, Identifiable, Hashable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let inputChannels: Int
    public let outputChannels: Int
    public let sampleRates: [Double]
    public let currentSampleRate: Double
    public let bufferFrameRange: ClosedRange<Int>
    public let currentBufferFrames: Int

    public var hasInput: Bool { inputChannels > 0 }
    public var hasOutput: Bool { outputChannels > 0 }
}

/// Device enumeration and configuration via the CoreAudio HAL.
public enum HALDeviceManager {
    public static func devices() -> [AudioDeviceInfo] {
        let ids = (try? HAL.getArray(
            AudioObjectID(kAudioObjectSystemObject),
            HAL.address(kAudioHardwarePropertyDevices),
            of: AudioDeviceID.self
        )) ?? []
        return ids.compactMap { info(for: $0) }
    }

    public static func info(for deviceID: AudioDeviceID) -> AudioDeviceInfo? {
        guard let name = try? HAL.getString(deviceID, HAL.address(kAudioDevicePropertyDeviceNameCFString)) else {
            return nil
        }
        let uid = (try? HAL.getString(deviceID, HAL.address(kAudioDevicePropertyDeviceUID))) ?? ""
        let inputs = HAL.channelCount(deviceID, scope: kAudioObjectPropertyScopeInput)
        let outputs = HAL.channelCount(deviceID, scope: kAudioObjectPropertyScopeOutput)
        let rateRanges = (try? HAL.getArray(
            deviceID, HAL.address(kAudioDevicePropertyAvailableNominalSampleRates), of: AudioValueRange.self
        )) ?? []
        var rates: [Double] = []
        for range in rateRanges {
            if range.mMinimum == range.mMaximum {
                rates.append(range.mMinimum)
            } else {
                for candidate in [44100.0, 48000, 88200, 96000, 176400, 192000]
                where candidate >= range.mMinimum && candidate <= range.mMaximum {
                    rates.append(candidate)
                }
            }
        }
        rates = Array(Set(rates)).sorted()
        let currentRate = (try? HAL.get(deviceID, HAL.address(kAudioDevicePropertyNominalSampleRate), default: 0.0)) ?? 0
        let bufferRange = (try? HAL.get(
            deviceID, HAL.address(kAudioDevicePropertyBufferFrameSizeRange),
            default: AudioValueRange(mMinimum: 32, mMaximum: 4096)
        )) ?? AudioValueRange(mMinimum: 32, mMaximum: 4096)
        let currentBuffer = (try? HAL.get(deviceID, HAL.address(kAudioDevicePropertyBufferFrameSize), default: UInt32(0))) ?? 0

        return AudioDeviceInfo(
            id: deviceID,
            uid: uid,
            name: name,
            inputChannels: inputs,
            outputChannels: outputs,
            sampleRates: rates,
            currentSampleRate: currentRate,
            bufferFrameRange: Int(bufferRange.mMinimum)...Int(max(bufferRange.mMinimum, bufferRange.mMaximum)),
            currentBufferFrames: Int(currentBuffer)
        )
    }

    public static func defaultInputDevice() -> AudioDeviceID? {
        let id = (try? HAL.get(
            AudioObjectID(kAudioObjectSystemObject),
            HAL.address(kAudioHardwarePropertyDefaultInputDevice),
            default: AudioDeviceID(0)
        )) ?? 0
        return id == 0 ? nil : id
    }

    public static func defaultOutputDevice() -> AudioDeviceID? {
        let id = (try? HAL.get(
            AudioObjectID(kAudioObjectSystemObject),
            HAL.address(kAudioHardwarePropertyDefaultOutputDevice),
            default: AudioDeviceID(0)
        )) ?? 0
        return id == 0 ? nil : id
    }

    public static func setNominalSampleRate(_ rate: Double, on deviceID: AudioDeviceID) throws {
        let current = try HAL.get(deviceID, HAL.address(kAudioDevicePropertyNominalSampleRate), default: 0.0)
        guard abs(current - rate) > 0.5 else { return }
        try HAL.set(deviceID, HAL.address(kAudioDevicePropertyNominalSampleRate), to: rate)
        // Rate changes are asynchronous; poll briefly until applied.
        for _ in 0..<50 {
            let now = (try? HAL.get(deviceID, HAL.address(kAudioDevicePropertyNominalSampleRate), default: 0.0)) ?? 0
            if abs(now - rate) < 0.5 { return }
            usleep(20_000)
        }
    }

    public static func setBufferFrameSize(_ frames: Int, on deviceID: AudioDeviceID) throws {
        try HAL.set(deviceID, HAL.address(kAudioDevicePropertyBufferFrameSize), to: UInt32(frames))
    }

    /// Reported one-direction latency: device + safety offset + first-stream
    /// latency + buffer frames (the JUCE/PortAudio/JACK formula).
    public static func reportedLatency(of deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> ReportedLatency {
        let device = (try? HAL.get(deviceID, HAL.address(kAudioDevicePropertyLatency, scope: scope), default: UInt32(0))) ?? 0
        let safety = (try? HAL.get(deviceID, HAL.address(kAudioDevicePropertySafetyOffset, scope: scope), default: UInt32(0))) ?? 0
        let buffer = (try? HAL.get(deviceID, HAL.address(kAudioDevicePropertyBufferFrameSize), default: UInt32(0))) ?? 0
        var stream: UInt32 = 0
        if let streams = try? HAL.getArray(deviceID, HAL.address(kAudioDevicePropertyStreams, scope: scope), of: AudioStreamID.self),
           let first = streams.first {
            stream = (try? HAL.get(first, HAL.address(kAudioStreamPropertyLatency), default: UInt32(0))) ?? 0
        }
        return ReportedLatency(
            deviceLatency: Int(device),
            safetyOffset: Int(safety),
            streamLatency: Int(stream),
            bufferFrames: Int(buffer)
        )
    }
}
