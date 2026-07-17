import Foundation
import RhythmAudio

/// ChannelMapping is the pure-math core of the DAW-style channel selection:
/// these tests pin down pair derivation, clamping of persisted values, and
/// the per-buffer write window the realtime output loop relies on.
@MainActor
struct ChannelMappingTests {
    func pairDerivation() {
        expect(ChannelMapping.outputPairs(channelCount: 0).isEmpty)

        let mono = ChannelMapping.outputPairs(channelCount: 1)
        expect(mono.count == 1)
        expect(mono[0].channels == 0...0)
        expect(mono[0].isMono)
        expect(mono[0].label == "Output 1")

        let stereo = ChannelMapping.outputPairs(channelCount: 2)
        expect(stereo.count == 1)
        expect(stereo[0].channels == 0...1)
        expect(!stereo[0].isMono)
        expect(stereo[0].label == "Output 1/2")

        let six = ChannelMapping.outputPairs(channelCount: 6)
        expect(six.count == 3)
        expect(six.map(\.channels) == [0...1, 2...3, 4...5])
        expect(six.map(\.index) == [0, 1, 2])

        let seven = ChannelMapping.outputPairs(channelCount: 7)
        expect(seven.count == 4)
        expect(seven.map(\.channels) == [0...1, 2...3, 4...5, 6...6])
        expect(seven[3].isMono)
        expect(seven[3].label == "Output 7")
        expect(seven[2].label == "Output 5/6")
    }

    func clamping() {
        expect(ChannelMapping.clampedPairIndex(0, channelCount: 2) == 0)
        expect(ChannelMapping.clampedPairIndex(2, channelCount: 7) == 2)
        expect(ChannelMapping.clampedPairIndex(3, channelCount: 7) == 3)
        expect(ChannelMapping.clampedPairIndex(4, channelCount: 7) == 0, "beyond range falls back to 0")
        expect(ChannelMapping.clampedPairIndex(1, channelCount: 2) == 0)
        expect(ChannelMapping.clampedPairIndex(-1, channelCount: 8) == 0)
        expect(ChannelMapping.clampedPairIndex(5, channelCount: 0) == 0, "empty device")

        expect(ChannelMapping.clampedInputChannel(0, channelCount: 1) == 0)
        expect(ChannelMapping.clampedInputChannel(7, channelCount: 8) == 7)
        expect(ChannelMapping.clampedInputChannel(8, channelCount: 8) == 0)
        expect(ChannelMapping.clampedInputChannel(-2, channelCount: 8) == 0)
        expect(ChannelMapping.clampedInputChannel(3, channelCount: 0) == 0)
    }

    func writeWindow() {
        // Interleaved: one 8-channel buffer, pair 2...3 selected.
        expect(ChannelMapping.localWriteWindow(bufferBase: 0, bufferChannels: 8, selected: 2...3) == 2..<4)

        // Non-interleaved: eight 1-channel buffers, only buffers 2 and 3 hit.
        for base in 0..<8 {
            let window = ChannelMapping.localWriteWindow(bufferBase: base, bufferChannels: 1, selected: 2...3)
            if base == 2 || base == 3 {
                expect(window == 0..<1, "buffer \(base)")
            } else {
                expect(window == nil, "buffer \(base)")
            }
        }

        // Selection 1...2 straddling two 2-channel buffers.
        expect(ChannelMapping.localWriteWindow(bufferBase: 0, bufferChannels: 2, selected: 1...2) == 1..<2)
        expect(ChannelMapping.localWriteWindow(bufferBase: 2, bufferChannels: 2, selected: 1...2) == 0..<1)

        // Mono tail 6...6 in an interleaved 7-channel buffer.
        expect(ChannelMapping.localWriteWindow(bufferBase: 0, bufferChannels: 7, selected: 6...6) == 6..<7)

        // Fully disjoint.
        expect(ChannelMapping.localWriteWindow(bufferBase: 4, bufferChannels: 2, selected: 0...1) == nil)
        expect(ChannelMapping.localWriteWindow(bufferBase: 0, bufferChannels: 2, selected: 4...5) == nil)

        // "All channels" sentinel must not overflow and covers every buffer.
        expect(ChannelMapping.localWriteWindow(bufferBase: 6, bufferChannels: 2, selected: 0...Int.max) == 0..<2)

        // Degenerate buffer.
        expect(ChannelMapping.localWriteWindow(bufferBase: 0, bufferChannels: 0, selected: 0...1) == nil)
    }
}
