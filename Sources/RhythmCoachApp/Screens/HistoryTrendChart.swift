import Charts
import RhythmCore
import SwiftUI

/// Timeline granularity for the History progress chart. Persisted via
/// `@AppStorage`, so it only needs `String`-backed `RawRepresentable`.
enum TrendGrouping: String, CaseIterable, Identifiable {
    case day = "Day"
    case week = "Week"
    var id: String { rawValue }
}

/// Median + inter-quartile (25–75) band for one metric within a time bucket,
/// already scaled to the chart's current unit (% of grid or ms).
struct BandStat {
    let median: Double
    let p25: Double
    let p75: Double
    /// Representative tier for coloring the median dot.
    let tier: TimingTier
}

/// One day or week of practice, aggregated across every take it contains.
struct TrendBucket: Identifiable {
    /// `startOfDay` (day grouping) or the week-of-year start (week grouping).
    let date: Date
    let count: Int
    let sd: BandStat
    let mean: BandStat
    var id: Date { date }
}

extension TrendBucket {
    /// Groups `sessions` into day/week buckets. Each session's sd/mean is mapped
    /// through `value` (so the %-vs-ms conversion is applied *before* the
    /// median/percentiles) and the median + 25/75 percentiles are taken across
    /// the bucket. Result is sorted ascending — Swift Charts needs a rising x.
    static func buckets(from sessions: [SessionRecord],
                        grouping: TrendGrouping,
                        value: (Double, SessionRecord) -> Double) -> [TrendBucket] {
        let cal = Calendar.current
        func key(_ s: SessionRecord) -> Date {
            switch grouping {
            case .day:
                return cal.startOfDay(for: s.startedAt)
            case .week:
                return cal.dateInterval(of: .weekOfYear, for: s.startedAt)?.start
                    ?? cal.startOfDay(for: s.startedAt)
            }
        }
        return Dictionary(grouping: sessions, by: key).map { date, group in
            let sd = group.map { value($0.sdMs, $0) }
            let mean = group.map { value($0.meanMs, $0) }
            return TrendBucket(
                date: date,
                count: group.count,
                sd: BandStat(median: sd.median, p25: sd.percentile(25), p75: sd.percentile(75),
                             tier: representativeTier(group, \.stability)),
                mean: BandStat(median: mean.median, p25: mean.percentile(25), p75: mean.percentile(75),
                               tier: representativeTier(group, \.accuracy))
            )
        }
        .sorted { $0.date < $1.date }
    }

    /// Median of the sessions' own tiers. Unit-agnostic and correct even when a
    /// bucket mixes tempos/subdivisions (there is no single grid to recompute a
    /// tier against). `.fair` when no session in the bucket is rated.
    private static func representativeTier(_ group: [SessionRecord],
                                           _ tier: KeyPath<TimingRating, TimingTier>) -> TimingTier {
        let tiers = group.compactMap { $0.rating?[keyPath: tier] }.sorted()
        return tiers.isEmpty ? .fair : tiers[tiers.count / 2]
    }
}

/// One stacked metric of the History progress chart: a median line with a
/// 25–75 percentile band across day/week buckets. `.sd` is zero-based (a lower
/// line is steadier); `.mean` is symmetric around a zero rule (0 = on the beat).
struct TrendMetricChart: View {
    let buckets: [TrendBucket]
    let metric: RollingMetric
    let grouping: TrendGrouping
    let unit: String

    private func stat(_ bucket: TrendBucket) -> BandStat {
        metric == .sd ? bucket.sd : bucket.mean
    }

    var body: some View {
        let spread = buckets.flatMap { [stat($0).p25, stat($0).p75, stat($0).median] }
        let maxAbs = spread.map(abs).max() ?? 1
        let yMax = max(maxAbs * 1.15, 1)               // guard against an all-zero set
        let yMin = metric == .sd ? 0 : -yMax
        let lineColor: Color = metric == .sd ? .blue : .orange

        Chart {
            // Band first → painted behind the rule/line/points (source = z-order).
            ForEach(buckets) { bucket in
                let s = stat(bucket)
                AreaMark(
                    x: .value("Date", bucket.date),
                    yStart: .value("p25", s.p25),
                    yEnd: .value("p75", s.p75)
                )
                .foregroundStyle(lineColor.opacity(0.15))
                .interpolationMethod(.monotone)
            }
            if metric == .mean {
                RuleMark(y: .value("Zero", 0))
                    .foregroundStyle(.secondary.opacity(0.4))
            }
            ForEach(buckets) { bucket in
                LineMark(
                    x: .value("Date", bucket.date),
                    y: .value("Median", stat(bucket).median)
                )
                .foregroundStyle(lineColor)
                .interpolationMethod(.monotone)
            }
            ForEach(buckets) { bucket in
                let s = stat(bucket)
                PointMark(
                    x: .value("Date", bucket.date),
                    y: .value("Median", s.median)
                )
                .foregroundStyle(s.tier.color)
                .symbolSize(40)
            }
        }
        .chartYScale(domain: yMin...yMax)
        .chartLegend(.hidden)
        .chartYAxisLabel(metric == .sd
            ? "SD — steadier is lower (\(unit))"
            : "bias — on the beat at 0 (\(unit))")
        .chartXAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(Self.xLabel(date, grouping))
                    }
                }
            }
        }
    }

    /// "12 Jul" for a day bucket; "wk 12 Jul" for the week starting that date.
    private static func xLabel(_ date: Date, _ grouping: TrendGrouping) -> String {
        let base = date.formatted(.dateTime.day().month(.abbreviated))
        return grouping == .week ? "wk \(base)" : base
    }
}
