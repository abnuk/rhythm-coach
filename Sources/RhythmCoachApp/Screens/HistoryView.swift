import Charts
import RhythmCore
import SwiftUI

struct HistoryView: View {
    @State private var sessions: [SessionRecord] = []
    @State private var selection: SessionRecord.ID?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                if sessions.count >= 2 {
                    trendChart
                        .frame(height: 180)
                        .padding()
                }
                List(sessions, selection: $selection) { session in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(session.startedAt, format: .dateTime.day().month().hour().minute())
                                .font(.headline)
                            Spacer()
                            Text(String(format: "%+.1f / %.1f ms", session.meanMs, session.sdMs))
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(session.sdMs <= 10 ? .green : .secondary)
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

    private var trendChart: some View {
        Chart {
            ForEach(sessions) { session in
                LineMark(
                    x: .value("Date", session.startedAt),
                    y: .value("SD", session.sdMs),
                    series: .value("Metric", "SD (stability)")
                )
                .foregroundStyle(.blue)
                PointMark(
                    x: .value("Date", session.startedAt),
                    y: .value("SD", session.sdMs)
                )
                .foregroundStyle(.blue)
                .symbolSize(30)
                LineMark(
                    x: .value("Date", session.startedAt),
                    y: .value("Mean", session.meanMs),
                    series: .value("Metric", "Mean (bias)")
                )
                .foregroundStyle(.orange)
                PointMark(
                    x: .value("Date", session.startedAt),
                    y: .value("Mean", session.meanMs)
                )
                .foregroundStyle(.orange)
                .symbolSize(30)
            }
            RuleMark(y: .value("Zero", 0))
                .foregroundStyle(.secondary.opacity(0.4))
        }
        .chartYAxisLabel("ms")
        .chartForegroundStyleScale([
            "SD (stability)": Color.blue,
            "Mean (bias)": Color.orange,
        ])
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
                        format: "latency comp %.2f ms (%@) · tolerance ±%d ms",
                        session.latencyCompMs, session.latencySource, Int(session.toleranceMs)
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    StatBox(title: "MEAN (bias)",
                            value: String(format: "%+.1f ms", session.meanMs),
                            detail: session.meanMs > 0 ? "behind the beat" : "ahead of the beat",
                            color: .primary)
                    StatBox(title: "SD (stability)",
                            value: String(format: "%.1f ms", session.sdMs),
                            detail: String(format: "%.1f%% of beat", session.sdMs / (60000 / session.bpm) * 100),
                            color: session.sdMs <= 10 ? .green : .primary)
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

                    Text("Distribution").font(.headline)
                    HistogramView(histogram: histogramFromHits, toleranceMs: session.toleranceMs)
                        .frame(height: 100)
                }

                if let path = session.audioPath {
                    if FileManager.default.fileExists(atPath: path) {
                        HStack {
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                            } label: {
                                Label("Show recording in Finder", systemImage: "waveform")
                            }
                            Button {
                                NSWorkspace.shared.open(URL(fileURLWithPath: path))
                            } label: {
                                Label("Play", systemImage: "play.circle")
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
}

struct SessionSummarySheet: View {
    let session: SessionRecord
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Session complete")
                .font(.title.weight(.semibold))
            Text(session.subtitle)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                StatBox(title: "MEAN (bias)",
                        value: String(format: "%+.1f ms", session.meanMs),
                        detail: session.meanMs > 0 ? "behind the beat" : "ahead of the beat",
                        color: .primary)
                StatBox(title: "SD (stability)",
                        value: String(format: "%.1f ms", session.sdMs),
                        detail: session.sdMs <= 10 ? "tight!" : "keep working",
                        color: session.sdMs <= 10 ? .green : .primary)
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
        var parts: [String] = []
        if abs(session.meanMs) <= 5 {
            parts.append("Bias is excellent (within ±5 ms).")
        } else if session.meanMs < 0 {
            parts.append(String(format: "You tend to rush by %.0f ms — the classic anticipation tendency.", -session.meanMs))
        } else {
            parts.append(String(format: "You sit %.0f ms behind the click.", session.meanMs))
        }
        if session.sdMs <= 10 {
            parts.append("Stability is in the pro range (SD ≤ 10 ms).")
        } else if session.sdMs <= 20 {
            parts.append("Stability is decent; slow the tempo to tighten further.")
        } else {
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
