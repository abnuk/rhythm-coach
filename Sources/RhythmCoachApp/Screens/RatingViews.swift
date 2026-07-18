import Charts
import RhythmCore
import SwiftUI

extension TimingTier {
    var color: Color {
        switch self {
        case .pro: .green
        case .good: .teal
        case .fair: .yellow
        case .poor: .orange
        }
    }

    var displayName: String { label.capitalized }
}

/// Small capsule showing a tier, e.g. next to a session row or sheet title.
struct TierBadge: View {
    let tier: TimingTier

    var body: some View {
        Text(tier.displayName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tier.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(tier.color.opacity(0.15), in: Capsule())
    }
}

extension SessionRecord {
    /// Analysis-grid slot interval in ms; 0 when bpm/subdivision are unusable
    /// (rows from before those fields, or an unknown subdivision string).
    var slotIOIMs: Double {
        guard let sub = Subdivision(rawValue: subdivision) else { return 0 }
        return TimingRating.slotIOIMs(bpm: bpm, subdivision: sub)
    }

    /// Rating recomputed from stored aggregates — works for old sessions too.
    var rating: TimingRating? {
        TimingRating(sdMs: sdMs, meanMs: meanMs, slotIOIMs: slotIOIMs, hitCount: hitCount)
    }

    /// "target advanced (±27 ms)" when a level was set; plain tolerance
    /// for old rows and Custom sessions.
    var targetDescription: String {
        if let raw = targetLevel, let level = TargetLevel(rawValue: raw) {
            return "target \(level.displayName.lowercased()) (±\(Int(toleranceMs.rounded())) ms)"
        }
        return "tolerance ±\(Int(toleranceMs.rounded())) ms"
    }
}

/// Which windowed statistic a `RollingStatChart` plots.
enum RollingMetric {
    /// Unsigned spread — stability thresholds, zero-based domain.
    case sd
    /// Signed bias — accuracy thresholds, symmetric domain around zero.
    case mean
}

/// Windowed SD or mean line over session time, on top of tier bands
/// computed for this session's slot interval (mirrored around zero for the
/// signed mean).
struct RollingStatChart: View {
    let points: [RollingPoint]
    let slotIOIMs: Double
    let metric: RollingMetric
    /// Fixed X range (session seconds) for the live scrolling window; `nil`
    /// auto-fits to the data, so the whole take shows (History / report).
    var xDomain: ClosedRange<Double>? = nil
    /// When set, a synchronized playback cursor is drawn at the current
    /// playhead. Read only inside the `ChartTimeCursor` leaf, never in this
    /// view's body, so 60 Hz ticks don't re-run the `Chart` builder.
    var playback: WaveformPlaybackController? = nil
    /// Latency compensation of the take, to map the raw-audio playhead onto
    /// this chart's compensated `timeSec` axis.
    var latencyCompMs: Double = 0

    var body: some View {
        let thresholds: TierThresholds = metric == .sd ? .stability : .accuracy
        let proMs = thresholds.proLimitMs(slotIOIMs: slotIOIMs)
        let goodMs = thresholds.goodLimitMs(slotIOIMs: slotIOIMs)
        let fairMs = thresholds.fairLimitMs(slotIOIMs: slotIOIMs)
        let values = points.map { metric == .sd ? $0.sdMs : $0.meanMs }
        let maxAbs = values.map(abs).max() ?? 0
        let yMax = max(maxAbs * 1.15, fairMs * 1.25)
        let yMin = metric == .sd ? 0 : -yMax
        let bands = tierBands(proMs: proMs, goodMs: goodMs, fairMs: fairMs, yMax: yMax)
        let chart = Chart {
            ForEach(bands.indices, id: \.self) { i in
                RectangleMark(
                    yStart: .value("Band", bands[i].from),
                    yEnd: .value("Band", bands[i].to)
                )
                .foregroundStyle(bands[i].tier.color.opacity(0.08))
            }
            if metric == .mean {
                RuleMark(y: .value("Zero", 0))
                    .foregroundStyle(.secondary.opacity(0.4))
            }
            ForEach(points.indices, id: \.self) { i in
                LineMark(
                    x: .value("Time", points[i].timeSec),
                    y: .value(metric == .sd ? "SD" : "Mean", values[i])
                )
                .foregroundStyle(metric == .sd ? Color.blue : Color.orange)
                .interpolationMethod(.monotone)
            }
        }
        .chartYScale(domain: yMin...yMax)
        .chartYAxisLabel(metric == .sd ? "SD ms" : "mean ms")
        .chartXAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let seconds = value.as(Double.self) {
                        Text(Self.timeLabel(seconds))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let ms = value.as(Double.self) {
                        Text("\(Int(ms))")
                    }
                }
            }
        }
        // Explicit X domain: live passes a fixed sliding window; otherwise fit
        // tight to the data so the whole-take view ends exactly at the last
        // point. (Charts' auto-fit pads out to the next round tick, leaving dead
        // space on the right.) Points are time-ordered, so first/last are ends.
        let xRange = xDomain ?? {
            let lo = points.first?.timeSec ?? 0
            let hi = points.last?.timeSec ?? 1
            return lo...(hi > lo ? hi : lo + 1)
        }()
        return chart
            .chartXScale(domain: xRange)
            .chartOverlay { proxy in
                Group {
                    if let playback {
                        ChartTimeCursor(proxy: proxy, playback: playback,
                                        latencyCompMs: latencyCompMs)
                    }
                }
            }
            .overlay(alignment: .bottomTrailing) {
            // Bottom corner: the top-trailing spot belongs to the Y-axis label.
            Text(String(
                format: metric == .sd
                    ? "pro ≤ %.0f · good ≤ %.0f · fair ≤ %.0f ms"
                    : "pro ≤ ±%.0f · good ≤ ±%.0f · fair ≤ ±%.0f ms",
                proMs, goodMs, fairMs
            ))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.bottom, 22)
            .padding(.trailing, 34)
        }
    }

    private func tierBands(proMs: Double, goodMs: Double, fairMs: Double,
                           yMax: Double) -> [(from: Double, to: Double, tier: TimingTier)] {
        switch metric {
        case .sd:
            return [
                (0, proMs, .pro),
                (proMs, goodMs, .good),
                (goodMs, fairMs, .fair),
                (fairMs, yMax, .poor),
            ]
        case .mean:
            return [
                (-proMs, proMs, .pro),
                (proMs, goodMs, .good), (-goodMs, -proMs, .good),
                (goodMs, fairMs, .fair), (-fairMs, -goodMs, .fair),
                (fairMs, yMax, .poor), (-yMax, -fairMs, .poor),
            ]
        }
    }

    private static func timeLabel(_ seconds: Double) -> String {
        String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

/// Thin playback cursor over a time-axis chart. This leaf is the only reader
/// of `playback.currentTime`, so 60 Hz ticks invalidate just it — never the
/// parent `Chart` builder. Mirrors `WaveformPlayheadOverlay` for the waveform.
private struct ChartTimeCursor: View {
    let proxy: ChartProxy
    let playback: WaveformPlaybackController
    let latencyCompMs: Double

    var body: some View {
        GeometryReader { geo in
            // The playhead runs on the raw-audio timeline; the chart's X axis
            // is latency-compensated (`onsetSample / sampleRate`), so shift.
            let cursorSec = playback.currentTime - latencyCompMs / 1000
            if playback.isAvailable, let plotFrame = proxy.plotFrame {
                let rect = geo[plotFrame]
                if let dx = proxy.position(forX: cursorSec), dx >= 0, dx <= rect.width {
                    Rectangle()
                        .fill(.red.opacity(0.9))
                        .frame(width: 1.5, height: rect.height)
                        .position(x: rect.minX + dx, y: rect.midY)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

extension SessionRecord {
    /// Natural-language session summary, shared by the post-take sheet and
    /// the exported report.
    var verdictText: String {
        guard let rating else {
            return "Not enough hits to rate this session."
        }
        var parts: [String] = []
        switch rating.accuracy {
        case .pro:
            parts.append("Bias is excellent — dead on the grid.")
        case .good:
            parts.append(String(format: "Bias is good (%+.0f ms).", meanMs))
        case .fair, .poor:
            if meanMs < 0 {
                parts.append(String(format: "You tend to rush by %.0f ms — the classic anticipation tendency.", -meanMs))
            } else {
                parts.append(String(format: "You sit %.0f ms behind the click.", meanMs))
            }
        }
        switch rating.stability {
        case .pro:
            parts.append("Stability is in the pro range.")
        case .good:
            parts.append("Solid stability — push the tempo or tighten toward pro.")
        case .fair:
            parts.append("Stability is fair; slow the tempo to tighten further.")
        case .poor:
            parts.append("High variance — drop the BPM and focus on consistency.")
        }
        if abs(driftMsPerMin) >= 5 {
            parts.append(String(
                format: "Watch the drift: you %@ by %.0f ms per minute.",
                driftMsPerMin < 0 ? "speed up" : "slow down",
                abs(driftMsPerMin)
            ))
        }
        return parts.joined(separator: " ")
    }
}
