import RhythmCore
import SwiftUI

/// Chart inputs derived from a session's stored hit rows, shared by the
/// history detail view and the exported report.
struct SessionChartData {
    let hits: [Hit]
    let histogram: [Int]
    let rollingPoints: [RollingPoint]

    init(session: SessionRecord, rows: [HitRow]) {
        hits = rows.map {
            Hit(slotIndex: $0.slotIndex, gridSample: 0, onsetSample: $0.onsetSample,
                deviationMs: $0.deviationMs, deviationPctIOI: 0, strength: 1)
        }
        var bins = [Int](repeating: 0, count: Histogram.binCount)
        for row in rows where row.kind == "hit" {
            bins[Histogram.bin(forDeviationMs: row.deviationMs)] += 1
        }
        histogram = bins
        if session.sampleRate > 0 {
            let hitRows = rows.filter { $0.kind == "hit" }.sorted { $0.onsetSample < $1.onsetSample }
            rollingPoints = RollingStats.windowedSD(
                timesSec: hitRows.map { $0.onsetSample / session.sampleRate },
                deviationsMs: hitRows.map(\.deviationMs)
            )
        } else {
            rollingPoints = []
        }
    }
}

/// Non-interactive, fixed-width session report rendered to PNG/PDF by
/// `SessionReportExporter`. Forced light so exports look the same
/// regardless of the app's appearance; must stay self-sized (no ScrollView,
/// explicit chart heights) and free of environment objects.
struct SessionReportView: View {
    let session: SessionRecord
    let hits: [HitRow]
    let displayName: String?

    var body: some View {
        let data = SessionChartData(session: session, rows: hits)
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    if let displayName {
                        Text(displayName)
                            .font(.title.weight(.semibold))
                        Text(session.startedAt, format: .dateTime.weekday().day().month().year().hour().minute())
                            .foregroundStyle(.secondary)
                    } else {
                        Text(session.startedAt, format: .dateTime.weekday().day().month().year().hour().minute())
                            .font(.title.weight(.semibold))
                    }
                    Text("\(session.subtitle) · \(Int(session.durationSec)) s · \(session.inputDeviceName)")
                        .foregroundStyle(.secondary)
                    Text(String(
                        format: "latency comp %.2f ms (%@) · tolerance ±%d ms",
                        session.latencyCompMs, session.latencySource, Int(session.toleranceMs)
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if let rating = session.rating {
                    TierBadge(tier: rating.overall)
                }
            }

            HStack(spacing: 12) {
                StatBox(title: "MEAN (bias)",
                        value: String(format: "%+.1f ms", session.meanMs),
                        detail: meanDetail,
                        color: session.rating?.accuracy.color ?? .primary)
                StatBox(title: "SD (stability)",
                        value: String(format: "%.1f ms", session.sdMs),
                        detail: sdDetail,
                        color: session.rating?.stability.color ?? .primary)
                StatBox(title: "IN TOLERANCE",
                        value: String(format: "%.0f%%", session.pctInTolerance),
                        detail: "\(session.hitCount) hits · \(session.missedCount) missed · \(session.extraCount) extra",
                        color: .primary)
                StatBox(title: "DRIFT",
                        value: String(format: "%+.1f ms/min", session.driftMsPerMin),
                        detail: String(format: "lag-1 %+.2f", session.lag1),
                        color: .primary)
            }

            Text("Deviation timeline").font(.headline)
            DeviationScatterView(hits: data.hits, toleranceMs: session.toleranceMs)
                .frame(height: 180)

            if !data.rollingPoints.isEmpty && session.slotIOIMs > 0 {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Bias over time (mean of last \(RollingStats.windowHits) hits)")
                            .font(.headline)
                        RollingStatChart(points: data.rollingPoints, slotIOIMs: session.slotIOIMs, metric: .mean)
                            .frame(height: 160)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Stability over time (SD of last \(RollingStats.windowHits) hits)")
                            .font(.headline)
                        RollingStatChart(points: data.rollingPoints, slotIOIMs: session.slotIOIMs, metric: .sd)
                            .frame(height: 160)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Text("Distribution").font(.headline)
            HistogramView(histogram: data.histogram, toleranceMs: session.toleranceMs)
                .frame(height: 100)

            Text(session.verdictText)
                .font(.callout)

            Text("RhythmCoach · exported \(Date().formatted(.dateTime.day().month().year().hour().minute()))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 800)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }

    private var meanDetail: String {
        let direction = session.meanMs > 0 ? "behind the beat" : "ahead of the beat"
        guard let rating = session.rating else { return direction }
        return "\(rating.accuracy.label) · \(direction)"
    }

    private var sdDetail: String {
        guard session.slotIOIMs > 0 else { return "—" }
        let pct = String(format: "%.1f%% of grid", session.sdMs / session.slotIOIMs * 100)
        guard let rating = session.rating else { return pct }
        return "\(rating.stability.label) · \(pct)"
    }
}
