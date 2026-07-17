import AVFoundation
import Foundation

/// Offline post-processing of a finished take: streams the mono float32
/// session WAV into two AAC .m4a files — the input as-is, and input + click
/// re-rendered offline. The click is delayed by `clickOffsetSamples` (the
/// session's net latency compensation) so it lands where the player heard it
/// relative to the recorded audio.
public enum SessionAudioCodec {
    public enum CodecError: Error, CustomStringConvertible {
        case cannotAllocate

        public var description: String {
            switch self {
            case .cannotAllocate: "cannot allocate audio buffers"
            }
        }
    }

    public struct EncodedTake: Sendable {
        public let inputURL: URL
        public let mixURL: URL
    }

    private static let chunkFrames: AVAudioFrameCount = 32768

    private static func aacSettings(sampleRate: Double, bitRate: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate,
        ]
    }

    /// Encodes the take WAV to `inputDestination` and a click-overlaid mix to
    /// `mixDestination` (both mono AAC .m4a), streaming in chunks so memory
    /// stays flat for long takes. The mix has the same length as the input;
    /// a click tail past the end is truncated. A click whose start would fall
    /// before file sample 0 (large negative compensation) is dropped.
    /// On failure both partial outputs are deleted before rethrowing.
    public static func encodeSession(
        sourceWAV: URL,
        inputDestination: URL,
        mixDestination: URL,
        grid: ClickGrid,
        sound: ClickSound,
        clickGain: Float,
        clickOffsetSamples: Double,
        bitRate: Int = 96_000
    ) throws -> EncodedTake {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: inputDestination)
        try? fileManager.removeItem(at: mixDestination)
        do {
            let source = try AVAudioFile(
                forReading: sourceWAV, commonFormat: .pcmFormatFloat32, interleaved: false
            )
            let sampleRate = source.processingFormat.sampleRate
            let settings = aacSettings(sampleRate: sampleRate, bitRate: bitRate)
            let inputFile = try AVAudioFile(
                forWriting: inputDestination, settings: settings,
                commonFormat: .pcmFormatFloat32, interleaved: false
            )
            let mixFile = try AVAudioFile(
                forWriting: mixDestination, settings: settings,
                commonFormat: .pcmFormatFloat32, interleaved: false
            )
            guard let monoFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                channels: 1, interleaved: false
            ),
                let readBuffer = AVAudioPCMBuffer(
                    pcmFormat: source.processingFormat, frameCapacity: chunkFrames
                ),
                let inputBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: chunkFrames),
                let mixBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: chunkFrames)
            else { throw CodecError.cannotAllocate }

            let renderer = ClickRenderer(grid: grid, sound: sound)
            let offset = Int64(clickOffsetSamples.rounded())
            var filePosition: Int64 = 0
            // read(into:) throws at EOF instead of returning 0 frames, so
            // the loop is bounded by the frame position.
            while source.framePosition < source.length {
                try source.read(into: readBuffer, frameCount: chunkFrames)
                let frames = Int(readBuffer.frameLength)
                if frames == 0 { break }

                downmix(readBuffer, into: inputBuffer, frames: frames)
                try inputFile.write(from: inputBuffer)

                let inputPtr = inputBuffer.floatChannelData![0]
                let mixPtr = mixBuffer.floatChannelData![0]
                for i in 0..<frames { mixPtr[i] = 0 }
                // Slot 0 lands at file position +offset: the click is placed
                // where the player heard it relative to the recorded input.
                renderer.render(
                    into: mixPtr, frames: frames,
                    startSample: filePosition - offset, gain: clickGain
                )
                for i in 0..<frames {
                    mixPtr[i] = max(-1, min(1, mixPtr[i] + inputPtr[i]))
                }
                mixBuffer.frameLength = AVAudioFrameCount(frames)
                try mixFile.write(from: mixBuffer)
                filePosition += Int64(frames)
            }
            return EncodedTake(inputURL: inputDestination, mixURL: mixDestination)
        } catch {
            try? fileManager.removeItem(at: inputDestination)
            try? fileManager.removeItem(at: mixDestination)
            throw error
        }
    }

    /// Decodes any AVAudioFile-readable file (m4a/AAC, also WAV) to mono
    /// float samples at the file's native rate; multi-channel is averaged.
    public static func readMono(url: URL) throws -> (samples: [Float], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw CodecError.cannotAllocate
        }
        var samples = [Float]()
        samples.reserveCapacity(Int(file.length))
        let channels = Int(format.channelCount)
        // read(into:) throws at EOF instead of returning 0 frames, so the
        // loop is bounded by the frame position.
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: chunkFrames)
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }
            let data = buffer.floatChannelData!
            if channels == 1 {
                samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: frames))
            } else {
                let scale = 1 / Float(channels)
                for i in 0..<frames {
                    var sum: Float = 0
                    for c in 0..<channels { sum += data[c][i] }
                    samples.append(sum * scale)
                }
            }
        }
        return (samples, format.sampleRate)
    }

    private static func downmix(_ source: AVAudioPCMBuffer, into mono: AVAudioPCMBuffer, frames: Int) {
        let data = source.floatChannelData!
        let out = mono.floatChannelData![0]
        let channels = Int(source.format.channelCount)
        if channels == 1 {
            out.update(from: data[0], count: frames)
        } else {
            let scale = 1 / Float(channels)
            for i in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += data[c][i] }
                out[i] = sum * scale
            }
        }
        mono.frameLength = AVAudioFrameCount(frames)
    }
}
