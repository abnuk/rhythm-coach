import Foundation

/// Sample-accurate metronome renderer. `render` is realtime-safe:
/// no allocation, no locks, no ObjC dispatch — call it only from the audio
/// render callback. All state is owned by the realtime thread.
public final class ClickRenderer {
    private let grid: ClickGrid
    private let accentBuf: [Float]
    private let beatBuf: [Float]
    private let subBuf: [Float]

    private struct Voice {
        var sound: Int32 = 0   // 0 accent, 1 beat, 2 sub
        var position: Int32 = 0
        var active: Bool = false
    }

    private var voices: [Voice]
    private var nextSlot: Int = 0

    public init(grid: ClickGrid, sound: ClickSound) {
        self.grid = grid
        let buffers = ClickSoundSynth.make(sound: sound, sampleRate: grid.sampleRate)
        self.accentBuf = buffers.accent
        self.beatBuf = buffers.beat
        self.subBuf = buffers.sub
        self.voices = Array(repeating: Voice(), count: 8)
    }

    /// Restarts the grid so the next rendered slot is the one at/after `sample`.
    public func reset(toSample sample: Int64) {
        nextSlot = max(0, Int((Double(sample) / grid.samplesPerSlot).rounded(.up)))
        for i in 0..<voices.count { voices[i].active = false }
    }

    /// Mixes click audio for `frames` output frames starting at absolute
    /// timeline position `startSample` into mono buffer `out` (additive).
    public func render(into out: UnsafeMutablePointer<Float>, frames: Int, startSample: Int64, gain: Float) {
        // Continue voices carried over from previous buffers FIRST, so a
        // voice claimed for a click starting in this buffer is not also
        // re-rendered from offset 0 within the same buffer.
        for v in 0..<voices.count where voices[v].active {
            let buf = buffer(for: voices[v].sound)
            var pos = Int(voices[v].position)
            var i = 0
            while i < frames && pos < buf.count {
                out[i] += buf[pos] * gain
                i += 1
                pos += 1
            }
            if pos >= buf.count {
                voices[v].active = false
            } else {
                voices[v].position = Int32(pos)
            }
        }

        // Start voices for every slot that begins inside this buffer.
        let bufferEnd = Double(startSample) + Double(frames)
        while grid.sampleTime(ofSlot: nextSlot) < bufferEnd {
            let slotTime = grid.sampleTime(ofSlot: nextSlot)
            let offset = Int((slotTime - Double(startSample)).rounded())
            if offset >= 0 && offset < frames && grid.isAudible(slot: nextSlot) {
                var soundIndex: Int32 = 2
                switch grid.kind(ofSlot: nextSlot) {
                case .downbeat: soundIndex = grid.spec.accentDownbeat ? 0 : 1
                case .beat: soundIndex = 1
                case .subdivision: soundIndex = 2
                }
                startVoice(sound: soundIndex, atFrame: offset, out: out, frames: frames, gain: gain)
            }
            nextSlot += 1
        }
    }

    private func startVoice(sound: Int32, atFrame offset: Int, out: UnsafeMutablePointer<Float>, frames: Int, gain: Float) {
        let buf = buffer(for: sound)
        var i = offset
        var pos = 0
        while i < frames && pos < buf.count {
            out[i] += buf[pos] * gain
            i += 1
            pos += 1
        }
        if pos < buf.count {
            // Tail continues into the next callback; claim a free voice slot.
            for v in 0..<voices.count where !voices[v].active {
                voices[v] = Voice(sound: sound, position: Int32(pos), active: true)
                return
            }
            // No free voice (should not happen with 8): drop the tail.
        }
    }

    private func buffer(for sound: Int32) -> [Float] {
        switch sound {
        case 0: accentBuf
        case 1: beatBuf
        default: subBuf
        }
    }
}
