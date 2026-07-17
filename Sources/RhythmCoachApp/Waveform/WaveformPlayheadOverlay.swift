import RhythmCore
import SwiftUI

/// Thin playback cursor over the waveform. This leaf view (plus the time
/// readout) is the only reader of `playback.currentTime`, so 30 Hz ticks
/// invalidate just these views — never the waveform canvas.
struct WaveformPlayheadOverlay: View {
    let playback: WaveformPlaybackController
    let viewport: WaveformViewport
    let sampleRate: Double
    /// Called with the playhead position in samples; the parent page-flips
    /// the viewport (outside this view's render) when the playhead leaves it.
    let onAutoFollow: (Double) -> Void

    var body: some View {
        let x = viewport.x(ofSample: playback.currentTime * sampleRate)
        ZStack(alignment: .leading) {
            if playback.isAvailable, viewport.widthPoints > 0,
               x >= 0, x <= viewport.widthPoints {
                Rectangle()
                    .fill(.red.opacity(0.9))
                    .frame(width: 1.5)
                    .offset(x: x)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .allowsHitTesting(false)
        .onChange(of: playback.currentTime) { _, time in
            guard playback.isPlaying else { return }
            onAutoFollow(time * sampleRate)
        }
    }
}

/// "0:03.2 / 0:17.1" toolbar readout.
struct PlaybackTimeReadout: View {
    let playback: WaveformPlaybackController

    var body: some View {
        Text("\(Self.format(playback.currentTime)) / \(Self.format(playback.duration))")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    /// Splits from whole deciseconds so rounding can't produce "0:60.0".
    private static func format(_ time: TimeInterval) -> String {
        let deciseconds = max(0, Int((time * 10).rounded()))
        return String(format: "%d:%04.1f", deciseconds / 600, Double(deciseconds % 600) / 10)
    }
}
