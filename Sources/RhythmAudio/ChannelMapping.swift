import Foundation

/// Pure integer math for DAW-style channel selection: stereo output pairs
/// derived from a device's channel count, defensive clamping of persisted
/// selections, and the per-buffer write window used by the realtime output
/// loop. No CoreAudio calls — everything here is unit-testable.
public enum ChannelMapping {
    /// A selectable output destination: a stereo pair, or the trailing mono
    /// channel on devices with an odd channel count.
    public struct OutputPair: Hashable, Sendable, Identifiable {
        /// 0-based pair index (what the UI persists and `EngineConfig` carries).
        public let index: Int
        /// 0-based device channels covered by the pair: 0...1, 2...3, or 6...6.
        public let channels: ClosedRange<Int>

        public var id: Int { index }
        public var isMono: Bool { channels.count == 1 }
        public var label: String {
            isMono
                ? "Output \(channels.lowerBound + 1)"
                : "Output \(channels.lowerBound + 1)/\(channels.upperBound + 1)"
        }

        public init(index: Int, channels: ClosedRange<Int>) {
            self.index = index
            self.channels = channels
        }
    }

    /// Stereo pairs for a device: pair i covers channels 2i...2i+1; an odd
    /// channel count yields a trailing mono entry. 0 channels yields [].
    public static func outputPairs(channelCount: Int) -> [OutputPair] {
        guard channelCount > 0 else { return [] }
        return (0..<((channelCount + 1) / 2)).map { index in
            let base = index * 2
            let top = min(base + 1, channelCount - 1)
            return OutputPair(index: index, channels: base...top)
        }
    }

    /// A persisted pair index that no longer fits the device falls back to 0.
    public static func clampedPairIndex(_ index: Int, channelCount: Int) -> Int {
        let count = (channelCount + 1) / 2
        return (0..<max(count, 1)).contains(index) ? index : 0
    }

    /// A persisted input channel that no longer fits the device falls back to 0.
    public static func clampedInputChannel(_ channel: Int, channelCount: Int) -> Int {
        (0..<max(channelCount, 1)).contains(channel) ? channel : 0
    }

    /// Local channels of an ABL buffer spanning
    /// [bufferBase, bufferBase + bufferChannels) that fall inside `selected`,
    /// or nil when disjoint. RT-safe: pure integer math, no allocation.
    @inlinable
    public static func localWriteWindow(
        bufferBase: Int, bufferChannels: Int, selected: ClosedRange<Int>
    ) -> Range<Int>? {
        guard bufferChannels > 0 else { return nil }
        let lo = max(selected.lowerBound - bufferBase, 0)
        // `selected.upperBound` may be Int.max ("all channels"); compare
        // before adding 1 so the math cannot overflow.
        let hi = selected.upperBound - bufferBase >= bufferChannels - 1
            ? bufferChannels
            : selected.upperBound - bufferBase + 1
        guard lo < hi else { return nil }
        return lo..<hi
    }
}
