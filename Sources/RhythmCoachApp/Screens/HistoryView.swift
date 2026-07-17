import Charts
import RhythmCore
import SwiftUI

struct HistoryView: View {
    @State private var sessions: [SessionRecord] = []
    @State private var selection: SessionRecord.ID?
    @State private var trendMode: TrendMode = .percent

    private enum TrendMode: String, CaseIterable, Identifiable {
        case percent = "% of grid"
        case ms = "ms"
        var id: String { rawValue }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                if sessions.count >= 2 {
                    trendChart
                        .frame(height: 210)
                        .padding()
                }
                List(sessions, selection: $selection) { session in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(session.startedAt, format: .dateTime.day().month().hour().minute())
                                .font(.headline)
                            Spacer()
                            if let rating = session.rating {
                                TierBadge(tier: rating.overall)
                            }
                            Text(String(format: "%+.1f / %.1f ms", session.meanMs, session.sdMs))
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(session.rating?.overall.color ?? .secondary)
                        }
                        Text(session.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(session.id)
                    .contextMenu {
                        Button("Delete session", role: .destructive) {
                            Database.shared.deleteSession(id: session.id)
                            reload()
                        }
                    }
                }
                .listStyle(.inset)
            }
            .frame(minWidth: 340, maxWidth: 460)

            if let session = sessions.first(where: { $0.id == selection }) {
                SessionDetailView(session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "Select a session",
                    systemImage: "clock.arrow.circlepath",
                    description: Text(sessions.isEmpty ? "Finished sessions will appear here." : "Pick a session to inspect.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        sessions = Database.shared.sessions()
    }

    /// Sessions the current trend mode can plot: % mode needs a known grid.
    private var trendSessions: [SessionRecord] {
        trendMode == .percent ? sessions.filter { $0.slotIOIMs > 0 } : sessions
    }

    /// SD/mean scaled for the current mode (ms, or % of the slot interval
    /// so sessions at different tempo/subdivision are comparable).
    private func trendValue(_ ms: Double, for session: SessionRecord) -> Double {
        trendMode == .percent ? ms / session.slotIOIMs * 100 : ms
    }

    private var trendChart: some View {
        VStack(spacing: 6) {
            Picker("Trend units", selection: $trendMode) {
                ForEach(TrendMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 220)
            Chart {
                ForEach(trendSessions) { session in
                    LineMark(
                        x: .value("Date", session.startedAt),
                        y: .value("SD", trendValue(session.sdMs, for: session)),
                        series: .value("Metric", "SD (stability)")
                    )
                    .foregroundStyle(.blue)
                    PointMark(
                        x: .value("Date", session.startedAt),
                        y: .value("SD", trendValue(session.sdMs, for: session))
                    )
                    .foregroundStyle((session.rating?.overall ?? .fair).color)
                    .symbolSize(40)
                    LineMark(
                        x: .value("Date", session.startedAt),
                        y: .value("Mean", trendValue(session.meanMs, for: session)),
                        series: .value("Metric", "Mean (bias)")
                    )
                    .foregroundStyle(.orange)
                    PointMark(
                        x: .value("Date", session.startedAt),
                        y: .value("Mean", trendValue(session.meanMs, for: session))
                    )
                    .foregroundStyle(.orange)
                    .symbolSize(30)
                }
                RuleMark(y: .value("Zero", 0))
                    .foregroundStyle(.secondary.opacity(0.4))
            }
            .chartYAxisLabel(trendMode == .percent ? "% of grid IOI" : "ms")
            .chartForegroundStyleScale([
                "SD (stability)": Color.blue,
                "Mean (bias)": Color.orange,
            ])
        }
    }
}

struct SessionDetailView: View {
    let session: SessionRecord
    @State private var hits: [HitRow] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.startedAt, format: .dateTime.weekday().day().month().year().hour().minute())
                        .font(.title2.weight(.semibold))
                    Text("\(session.subtitle) · \(Int(session.durationSec)) s · \(session.inputDeviceName)")
                        .foregroundStyle(.secondary)
                    Text(String(
                        format: "latency comp %.2f ms (%@) · %@",
                        session.latencyCompMs, session.latencySource, session.targetDescription
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

                if !hits.isEmpty {
                    Text("Deviation timeline").font(.headline)
                    DeviationScatterView(
                        hits: hits.map {
                            Hit(slotIndex: $0.slotIndex, gridSample: 0, onsetSample: $0.onsetSample,
                                deviationMs: $0.deviationMs, deviationPctIOI: 0, strength: 1)
                        },
                        toleranceMs: session.toleranceMs
                    )
                    .frame(height: 180)

                    if !rollingPoints.isEmpty && session.slotIOIMs > 0 {
                        Text("Stability over time (SD of last \(RollingStats.windowHits) hits)")
                            .font(.headline)
                        RollingSDChart(points: rollingPoints, slotIOIMs: session.slotIOIMs)
                            .frame(height: 160)
                    }

                    Text("Distribution").font(.headline)
                    HistogramView(histogram: histogramFromHits, toleranceMs: session.toleranceMs)
                        .frame(height: 100)
                }

                if let path = session.audioPath {
                    if FileManager.default.fileExists(atPath: path) {
                        let mixPath = session.clickMixPath.flatMap {
                            FileManager.default.fileExists(atPath: $0) ? $0 : nil
                        }
                        Text("Waveform").font(.headline)
                        WaveformSessionView(
                            audioURL: URL(fileURLWithPath: path),
                            mixURL: mixPath.map { URL(fileURLWithPath: $0) },
                            grid: WaveformGridParams(record: session),
                            hits: WaveformHitMarker.markers(rows: hits, record: session)
                        )
                        .frame(height: 260)
                        HStack {
                            Button {
                                let urls = [path, mixPath].compactMap { $0.map { URL(fileURLWithPath: $0) } }
                                NSWorkspace.shared.activateFileViewerSelecting(urls)
                            } label: {
                                Label("Show recording in Finder", systemImage: "waveform")
                            }
                        }
                    } else {
                        Text("Recording deleted")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
        }
        .task(id: session.id) {
            hits = Database.shared.hits(sessionID: session.id)
        }
    }

    private var histogramFromHits: [Int] {
        var bins = [Int](repeating: 0, count: Histogram.binCount)
        for hit in hits where hit.kind == "hit" {
            bins[Histogram.bin(forDeviationMs: hit.deviationMs)] += 1
        }
        return bins
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

    private var rollingPoints: [RollingPoint] {
        guard session.sampleRate > 0 else { return [] }
        let hitRows = hits.filter { $0.kind == "hit" }.sorted { $0.onsetSample < $1.onsetSample }
        return RollingStats.windowedSD(
            timesSec: hitRows.map { $0.onsetSample / session.sampleRate },
            deviationsMs: hitRows.map(\.deviationMs)
        )
    }
}

struct SessionSummarySheet: View {
    let session: SessionRecord
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Text("Session complete")
                    .font(.title.weight(.semibold))
                if let rating = session.rating {
                    TierBadge(tier: rating.overall)
                }
            }
            Text(session.subtitle)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                StatBox(title: "MEAN (bias)",
                        value: String(format: "%+.1f ms", session.meanMs),
                        detail: session.rating.map {
                            "\($0.accuracy.label) · \(session.meanMs > 0 ? "behind the beat" : "ahead of the beat")"
                        } ?? (session.meanMs > 0 ? "behind the beat" : "ahead of the beat"),
                        color: session.rating?.accuracy.color ?? .primary)
                StatBox(title: "SD (stability)",
                        value: String(format: "%.1f ms", session.sdMs),
                        detail: session.rating?.stability.label ?? "—",
                        color: session.rating?.stability.color ?? .primary)
                StatBox(title: "IN TOLERANCE",
                        value: String(format: "%.0f%%", session.pctInTolerance),
                        detail: "\(session.hitCount) hits",
                        color: .primary)
            }

            Text(verdict)
                .font(.callout)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 620)
    }

    private var verdict: String {
        guard let rating = session.rating else {
            return "Not enough hits to rate this session."
        }
        var parts: [String] = []
        switch rating.accuracy {
        case .pro:
            parts.append("Bias is excellent — dead on the grid.")
        case .good:
            parts.append(String(format: "Bias is good (%+.0f ms).", session.meanMs))
        case .fair, .poor:
            if session.meanMs < 0 {
                parts.append(String(format: "You tend to rush by %.0f ms — the classic anticipation tendency.", -session.meanMs))
            } else {
                parts.append(String(format: "You sit %.0f ms behind the click.", session.meanMs))
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
        if abs(session.driftMsPerMin) >= 5 {
            parts.append(String(
                format: "Watch the drift: you %@ by %.0f ms per minute.",
                session.driftMsPerMin < 0 ? "speed up" : "slow down",
                abs(session.driftMsPerMin)
            ))
        }
        return parts.joined(separator: " ")
    }
}
