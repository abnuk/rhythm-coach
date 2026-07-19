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

// MARK: - Plain-language help

/// A beginner-friendly explanation surfaced from an `InfoButton` popover.
struct HelpTopic {
    let title: String
    let body: String
}

/// Every stat/chart explanation kept in one place so the wording is easy to
/// tune. Voice matches `verdictText`: plain, concrete, no jargon — written for
/// someone who has never heard of "standard deviation".
enum HelpTopics {
    static let mean = HelpTopic(
        title: "Mean — your average timing",
        body: """
        On average, are you ahead of or behind the beat? Around 0 ms means you're \
        right on the grid. A positive number (like +5 ms) means you tend to play a \
        hair late — just behind the beat. A negative number means early — a bit \
        ahead. This is your steady lean, not how spread out your notes are.
        """
    )

    static let sd = HelpTopic(
        title: "SD — how steady you are",
        body: """
        How consistent your timing is from note to note — your typical wobble around \
        your own average. Smaller is better. Rule of thumb: about 2 out of 3 of your \
        notes land within one SD of your average, and about 19 in 20 within twice \
        that. So SD 15 ms means roughly two-thirds of your notes fall inside a ±15 ms \
        band, and almost all within ±30 ms. It measures how tight you are, not how \
        early or late — playing steadily but late still scores a low SD.
        """
    )

    static let inTolerance = HelpTopic(
        title: "In tolerance — notes on target",
        body: """
        The share of your notes that landed inside the target window around the \
        beat. 100% means every note was on target; a lower number means more notes \
        fell outside the window. "Missed" counts beats you didn't play; "extra" \
        counts notes that had no beat to match.
        """
    )

    static let drift = HelpTopic(
        title: "Drift — is your tempo slipping?",
        body: """
        Whether your tempo drifts as the take goes on. Near 0 means you held steady. \
        A positive number means you gradually slowed down; a negative number means \
        you sped up (rushed) toward the end. Measured in milliseconds per minute.
        """
    )

    static let minMax = HelpTopic(
        title: "Min / Max — your extremes",
        body: """
        Your single earliest and latest notes in the take, and the total gap between \
        them. Handy for spotting a one-off slip that your average hides — one wild \
        note can stretch this range even when the rest were tight.
        """
    )

    static let biasChart = HelpTopic(
        title: "Bias over time",
        body: """
        Your early/late lean tracked across the take (the average of your last 16 \
        hits). The center line is dead on the beat. Watch whether the line drifts \
        away from center — that's your timing sliding early or late as you play.
        """
    )

    static let stabilityChart = HelpTopic(
        title: "Stability over time",
        body: """
        How tight your timing is across the take (the spread of your last 16 hits). \
        Lower is better. A line creeping up means you're getting less consistent; a \
        line settling down means you're tightening up.
        """
    )

    static let deviationScatter = HelpTopic(
        title: "Every note, in order",
        body: """
        One dot per note, left to right in the order you played them. How high or \
        low a dot sits shows how far it landed from the beat — orange = early, \
        purple = late. The green band is the on-target window; dots inside it are \
        good hits.
        """
    )

    static let histogram = HelpTopic(
        title: "Where your notes cluster",
        body: """
        How your notes are spread around the beat. A tall stack in the middle (the \
        green band) means most notes were on target. Bars leaning to one side show a \
        habit of playing early (orange, left) or late (purple, right).
        """
    )

    static let trendChart = HelpTopic(
        title: "Your progress over sessions",
        body: """
        Your timing across past practice sessions. Blue tracks how steady you were \
        (SD); orange tracks your early/late lean (mean). Lines heading toward the \
        center line over time mean you're improving.
        """
    )
}

/// Small ⓘ button that reveals a plain-language explanation in a popover.
/// Sits next to a stat tile or chart title so a beginner can learn what a number
/// means without cluttering the layout. Styled to read as a quiet, secondary
/// affordance (matches the app's gray caption idiom).
struct InfoButton: View {
    let topic: HelpTopic
    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.secondary)
        .help(topic.title)
        .popover(isPresented: $showing, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(topic.title)
                    .font(.headline)
                Text(topic.body)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(width: 300, alignment: .leading)
        }
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
