import Charts
import RhythmCore
import SwiftUI

struct HistoryView: View {
    @State private var sessions: [SessionRecord] = []
    @State private var displayNames: [SessionRecord.ID: String] = [:]
    @State private var selection: SessionRecord.ID?
    @AppStorage("ui.historyTrendMode") private var trendMode: TrendMode = .percent
    @AppStorage("ui.historyTrendGrouping") private var trendGrouping: TrendGrouping = .day
    @State private var renameTargetID: SessionRecord.ID?
    @State private var renameText = ""

    private enum TrendMode: String, CaseIterable, Identifiable {
        case percent = "% of grid"
        case ms = "ms"
        var id: String { rawValue }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                if sessions.count >= 2 {
                    trendChart(trendBuckets)
                        .padding()
                }
                List(sessions, selection: $selection) { session in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            if let name = displayNames[session.id] {
                                Text(name)
                                    .font(.headline)
                            } else {
                                Text(session.startedAt, format: .dateTime.day().month().hour().minute())
                                    .font(.headline)
                            }
                            Spacer()
                            if let rating = session.rating {
                                TierBadge(tier: rating.overall)
                            }
                            Text(String(format: "%+.1f / %.1f ms", session.meanMs, session.sdMs))
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(session.rating?.overall.color ?? .secondary)
                        }
                        if displayNames[session.id] != nil {
                            Text("\(session.startedAt, format: .dateTime.day().month().hour().minute()) · \(session.subtitle)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(session.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(session.id)
                    .contextMenu {
                        Button("Rename session…") {
                            renameText = session.name ?? ""
                            renameTargetID = session.id
                        }
                        Button("Delete session", role: .destructive) {
                            Database.shared.deleteSession(id: session.id)
                            reload()
                        }
                    }
                }
                .listStyle(.inset)
                .alert("Rename session", isPresented: renameActive) {
                    TextField("Name", text: $renameText)
                    Button("Save") { commitRename() }
                    Button("Cancel", role: .cancel) { renameTargetID = nil }
                } message: {
                    Text("Leave empty to remove the name.")
                }
            }
            .frame(minWidth: 340, maxWidth: 460)

            if let session = sessions.first(where: { $0.id == selection }) {
                SessionDetailView(session: session, displayName: displayNames[session.id])
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
        displayNames = SessionNaming.displayNames(for: sessions)
    }

    private var renameActive: Binding<Bool> {
        Binding(get: { renameTargetID != nil }, set: { if !$0 { renameTargetID = nil } })
    }

    private func commitRename() {
        guard let id = renameTargetID else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        Database.shared.updateSessionName(id: id, name: trimmed.isEmpty ? nil : trimmed)
        renameTargetID = nil
        reload()
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

    private var trendBuckets: [TrendBucket] {
        TrendBucket.buckets(from: trendSessions, grouping: trendGrouping,
                            value: { trendValue($0, for: $1) })
    }

    private func trendChart(_ buckets: [TrendBucket]) -> some View {
        let unit = trendMode == .percent ? "% of grid IOI" : "ms"
        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                Picker("Trend units", selection: $trendMode) {
                    ForEach(TrendMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Picker("Grouping", selection: $trendGrouping) {
                    ForEach(TrendGrouping.allCases) { grouping in
                        Text(grouping.rawValue).tag(grouping)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                InfoButton(topic: HelpTopics.trendChart)
            }
            if buckets.count >= 2 {
                TrendMetricChart(buckets: buckets, metric: .sd, grouping: trendGrouping, unit: unit)
                    .frame(height: 150)
                TrendMetricChart(buckets: buckets, metric: .mean, grouping: trendGrouping, unit: unit)
                    .frame(height: 150)
            } else {
                Text(trendEmptyMessage(bucketCount: buckets.count))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .padding(.horizontal)
            }
        }
    }

    /// Shown when the chosen grouping has fewer than two buckets to connect.
    /// The units/grouping toggles stay visible above, so this is never a dead
    /// end — the player can always switch back to a view that has data.
    private func trendEmptyMessage(bucketCount: Int) -> String {
        if bucketCount == 0 {
            return "No sessions with a known grid yet — switch to ms to include them."
        }
        return trendGrouping == .week
            ? "Just one week of practice so far. Switch to Day to see it now, or come back after practicing another week."
            : "Just one day of practice so far. The trend appears once you've practiced on another day."
    }
}

struct SessionDetailView: View {
    let session: SessionRecord
    var displayName: String? = nil
    @State private var hits: [HitRow] = []
    @State private var exportError: String?
    /// Shared by the waveform and the stat charts so one playhead clock drives
    /// every synchronized position marker.
    @State private var playback = WaveformPlaybackController()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        if let displayName {
                            Text(displayName)
                                .font(.title2.weight(.semibold))
                        } else {
                            Text(session.startedAt, format: .dateTime.weekday().day().month().year().hour().minute())
                                .font(.title2.weight(.semibold))
                        }
                        Spacer()
                        exportMenu
                    }
                    if displayName != nil {
                        Text(session.startedAt, format: .dateTime.weekday().day().month().year().hour().minute())
                            .foregroundStyle(.secondary)
                    }
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
                            color: session.rating?.accuracy.color ?? .primary,
                            help: HelpTopics.mean)
                    StatBox(title: "SD (stability)",
                            value: String(format: "%.1f ms", session.sdMs),
                            detail: sdDetail,
                            color: session.rating?.stability.color ?? .primary,
                            help: HelpTopics.sd)
                    StatBox(title: "IN TOLERANCE",
                            value: String(format: "%.0f%%", session.pctInTolerance),
                            detail: "\(session.hitCount) hits · \(session.missedCount) missed · \(session.extraCount) extra",
                            color: .primary,
                            help: HelpTopics.inTolerance)
                    StatBox(title: "DRIFT",
                            value: String(format: "%+.1f ms/min", session.driftMsPerMin),
                            detail: String(format: "lag-1 %+.2f", session.lag1),
                            color: .primary,
                            help: HelpTopics.drift)
                }

                if !hits.isEmpty {
                    let data = SessionChartData(session: session, rows: hits)
                    HStack(spacing: 4) {
                        Text("Deviation timeline").font(.headline)
                        InfoButton(topic: HelpTopics.deviationScatter)
                    }
                    DeviationScatterView(hits: data.hits, toleranceMs: session.toleranceMs,
                                         playback: playback, sampleRate: session.sampleRate,
                                         latencyCompMs: session.latencyCompMs,
                                         windowToRecent: false)
                        .frame(height: 180)

                    if !data.rollingPoints.isEmpty && session.slotIOIMs > 0 {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 4) {
                                    Text("Bias over time (mean of last \(RollingStats.windowHits) hits)")
                                        .font(.headline)
                                    InfoButton(topic: HelpTopics.biasChart)
                                }
                                RollingStatChart(points: data.rollingPoints, slotIOIMs: session.slotIOIMs,
                                                 metric: .mean, playback: playback,
                                                 latencyCompMs: session.latencyCompMs)
                                    .frame(height: 160)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 4) {
                                    Text("Stability over time (SD of last \(RollingStats.windowHits) hits)")
                                        .font(.headline)
                                    InfoButton(topic: HelpTopics.stabilityChart)
                                }
                                RollingStatChart(points: data.rollingPoints, slotIOIMs: session.slotIOIMs,
                                                 metric: .sd, playback: playback,
                                                 latencyCompMs: session.latencyCompMs)
                                    .frame(height: 160)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    HStack(spacing: 4) {
                        Text("Distribution").font(.headline)
                        InfoButton(topic: HelpTopics.histogram)
                    }
                    HistogramView(histogram: data.histogram, toleranceMs: session.toleranceMs)
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
                            hits: WaveformHitMarker.markers(rows: hits, record: session),
                            playback: playback
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
            // Switching sessions must halt any in-progress playback, even when
            // the new session has no audio (the waveform view won't appear to
            // stop it via .onDisappear).
            playback.stop()
            hits = Database.shared.hits(sessionID: session.id)
        }
    }

    private var exportMenu: some View {
        Menu {
            Button("Export as PNG…") { export(as: .png) }
            Button("Export as PDF…") { export(as: .pdf) }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .fixedSize()
        .alert("Export failed", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    private func export(as format: SessionReportExporter.Format) {
        exportError = SessionReportExporter.promptAndExport(
            session: session, hits: hits, displayName: displayName, format: format
        )
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

struct SessionSummarySheet: View {
    let session: SessionRecord
    @Environment(\.dismiss) private var dismiss
    @State private var exportError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Text("Session complete")
                    .font(.title.weight(.semibold))
                if let rating = session.rating {
                    TierBadge(tier: rating.overall)
                }
            }
            if let name = session.name {
                Text(name)
                    .font(.title3.weight(.medium))
            }
            Text(session.subtitle)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                StatBox(title: "MEAN (bias)",
                        value: String(format: "%+.1f ms", session.meanMs),
                        detail: session.rating.map {
                            "\($0.accuracy.label) · \(session.meanMs > 0 ? "behind the beat" : "ahead of the beat")"
                        } ?? (session.meanMs > 0 ? "behind the beat" : "ahead of the beat"),
                        color: session.rating?.accuracy.color ?? .primary,
                        help: HelpTopics.mean)
                StatBox(title: "SD (stability)",
                        value: String(format: "%.1f ms", session.sdMs),
                        detail: session.rating?.stability.label ?? "—",
                        color: session.rating?.stability.color ?? .primary,
                        help: HelpTopics.sd)
                StatBox(title: "IN TOLERANCE",
                        value: String(format: "%.0f%%", session.pctInTolerance),
                        detail: "\(session.hitCount) hits",
                        color: .primary,
                        help: HelpTopics.inTolerance)
            }

            Text(session.verdictText)
                .font(.callout)

            HStack {
                Menu {
                    Button("Export as PNG…") { export(as: .png) }
                    Button("Export as PDF…") { export(as: .pdf) }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .fixedSize()
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 620)
        .alert("Export failed", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    private func export(as format: SessionReportExporter.Format) {
        exportError = SessionReportExporter.promptAndExport(
            session: session,
            hits: Database.shared.hits(sessionID: session.id),
            displayName: session.name,
            format: format
        )
    }
}
