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

/// Windowed-SD line over session time, on top of stability tier bands
/// computed for this session's slot interval.
struct RollingSDChart: View {
    let points: [RollingPoint]
    let slotIOIMs: Double

    var body: some View {
        let proMs = TierThresholds.stability.proLimitMs(slotIOIMs: slotIOIMs)
        let goodMs = TierThresholds.stability.goodLimitMs(slotIOIMs: slotIOIMs)
        let fairMs = TierThresholds.stability.fairLimitMs(slotIOIMs: slotIOIMs)
        let maxSD = points.map(\.sdMs).max() ?? 0
        let yMax = max(maxSD * 1.15, fairMs * 1.25)
        Chart {
            RectangleMark(yStart: .value("SD", 0), yEnd: .value("SD", proMs))
                .foregroundStyle(TimingTier.pro.color.opacity(0.08))
            RectangleMark(yStart: .value("SD", proMs), yEnd: .value("SD", goodMs))
                .foregroundStyle(TimingTier.good.color.opacity(0.08))
            RectangleMark(yStart: .value("SD", goodMs), yEnd: .value("SD", fairMs))
                .foregroundStyle(TimingTier.fair.color.opacity(0.08))
            RectangleMark(yStart: .value("SD", fairMs), yEnd: .value("SD", yMax))
                .foregroundStyle(TimingTier.poor.color.opacity(0.08))
            ForEach(points.indices, id: \.self) { i in
                LineMark(
                    x: .value("Time", points[i].timeSec),
                    y: .value("SD", points[i].sdMs)
                )
                .foregroundStyle(.blue)
                .interpolationMethod(.monotone)
            }
        }
        .chartYScale(domain: 0...yMax)
        .chartYAxisLabel("SD ms")
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
        .overlay(alignment: .topTrailing) {
            Text(String(format: "pro ≤ %.0f · good ≤ %.0f · fair ≤ %.0f ms", proMs, goodMs, fairMs))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(6)
        }
    }

    private static func timeLabel(_ seconds: Double) -> String {
        String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}
