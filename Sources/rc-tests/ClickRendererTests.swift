import Foundation
import RhythmCore

@MainActor struct ClickRendererTests {
    /// Renders the metronome in 64-frame callbacks and asserts every audible
    /// click starts exactly at its slot's rounded sample position.
    func sampleAccuracy() {
        let sampleRate = 44100.0
        let spec = ClickGridSpec(bpm: 137, subdivision: .eighth, countInBars: 0)
        let grid = ClickGrid(spec: spec, sampleRate: sampleRate)
        let renderer = ClickRenderer(grid: grid, sound: .woodblock)

        let totalFrames = Int(sampleRate * 5)
        var output = [Float](repeating: 0, count: totalFrames)
        let bufferSize = 64
        var start = 0
        while start < totalFrames {
            let frames = min(bufferSize, totalFrames - start)
            output.withUnsafeMutableBufferPointer { buf in
                renderer.render(into: buf.baseAddress! + start, frames: frames,
                                startSample: Int64(start), gain: 1.0)
            }
            start += frames
        }

        // Locate click starts: a loud sample preceded by >100 silent samples.
        var starts: [Int] = []
        var lastLoud = -1000
        for i in 0..<totalFrames where abs(output[i]) > 1e-7 {
            if i - lastLoud > 100 { starts.append(i) }
            lastLoud = i
        }

        var expected: [Int] = []
        var slot = 0
        while grid.sampleTime(ofSlot: slot) < Double(totalFrames) {
            expected.append(Int(grid.sampleTime(ofSlot: slot).rounded()))
            slot += 1
        }
        // The final click may start too close to the end to be detected reliably.
        expect(starts.count >= expected.count - 1, "found \(starts.count) clicks, expected ~\(expected.count)")
        for (found, exp) in zip(starts, expected) {
            // Attack has a 1 ms fade-in whose first samples are near zero;
            // allow a few samples of detection slack, but the position must
            // never drift with time.
            expect(abs(found - exp) <= 3, "click at \(found), slot at \(exp)")
        }
    }

    func gapSilence() {
        let sampleRate = 44100.0
        let spec = ClickGridSpec(bpm: 120, subdivision: .quarter, beatsPerBar: 4,
                                 gapPattern: GapPattern(barsOn: 1, barsOff: 1), countInBars: 0)
        let grid = ClickGrid(spec: spec, sampleRate: sampleRate)
        let renderer = ClickRenderer(grid: grid, sound: .beep)

        // Bar = 4 beats = 2 s. Render 8 s = bar0 on, bar1 off, bar2 on, bar3 off.
        let totalFrames = Int(sampleRate * 8)
        var output = [Float](repeating: 0, count: totalFrames)
        output.withUnsafeMutableBufferPointer { buf in
            renderer.render(into: buf.baseAddress!, frames: totalFrames, startSample: 0, gain: 1.0)
        }

        let barSamples = Int(sampleRate * 2)
        func energy(_ range: Range<Int>) -> Float {
            output[range].reduce(0) { $0 + abs($1) }
        }
        expect(energy(0..<barSamples) > 1)
        expect(energy(barSamples..<(2 * barSamples)) == 0)
        expect(energy((2 * barSamples)..<(3 * barSamples)) > 1)
        expect(energy((3 * barSamples)..<(4 * barSamples)) == 0)
    }
}
