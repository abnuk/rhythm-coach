import RhythmCore
import SwiftUI

struct PracticeView: View {
    @Environment(TransportController.self) private var transport

    var body: some View {
        @Bindable var transport = transport
        HSplitView {
            controls
                .frame(minWidth: 290, maxWidth: 340)
            VStack(spacing: 12) {
                SessionNameField()
                header
                statsRow
                DeviationScatterView(
                    hits: transport.liveHits,
                    toleranceMs: transport.toleranceMs
                )
                .frame(minHeight: 120)
                LiveRollingChartsView(
                    hits: transport.liveHits,
                    sampleRate: transport.sampleRate,
                    slotIOIMs: liveSlotIOIMs,
                    isRunning: transport.isRunning
                )
                .frame(minHeight: 130)
                HistogramView(histogram: transport.snapshot.histogram, toleranceMs: transport.toleranceMs)
                    .frame(height: 110)
                if transport.isEncodingTake {
                    ProgressView("Preparing take audio…")
                        .controlSize(.small)
                }
                if !transport.isRunning,
                   let session = transport.lastSession,
                   let path = session.audioPath {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Last take")
                            .font(.headline)
                        WaveformSessionView(
                            audioURL: URL(fileURLWithPath: path),
                            mixURL: session.clickMixPath.map { URL(fileURLWithPath: $0) },
                            grid: WaveformGridParams(record: session),
                            hits: WaveformHitMarker.markers(hits: transport.lastSessionHits, record: session)
                        )
                        .frame(minHeight: 200, idealHeight: 240)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(item: $transport.finishedSession) { session in
            SessionSummarySheet(session: session)
        }
    }

    // MARK: - Left column

    private var controls: some View {
        @Bindable var transport = transport
        return Form {
            Section("Click") {
                HStack {
                    Text("BPM")
                    Slider(value: $transport.bpm, in: 30...300, step: 1)
                    Text("\(Int(transport.bpm))")
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }
                Picker("Grid (tracked)", selection: $transport.subdivision) {
                    ForEach(Subdivision.allCases) { sub in
                        Text(sub.displayName).tag(sub)
                    }
                }
                .pickerStyle(.segmented)
                Picker("Click on", selection: $transport.clickDensity) {
                    ForEach(ClickDensity.allCases) { density in
                        Text(density.displayName).tag(density)
                    }
                }
                if transport.clickDensity != .everySlot && transport.subdivision != .quarter {
                    Text("You hear \(transport.clickDensity == .beatsOnly ? "quarter-note clicks" : "one click per bar"); every \(transport.subdivision.displayName) you play is still tracked.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Picker("Sound", selection: $transport.clickSound) {
                    ForEach(ClickSound.allCases) { sound in
                        Text(sound.displayName).tag(sound)
                    }
                }
                Stepper("Beats per bar: \(transport.beatsPerBar)", value: $transport.beatsPerBar, in: 2...12)
                Toggle("Accent downbeat", isOn: $transport.accentDownbeat)
                Stepper("Count-in bars: \(transport.countInBars)", value: $transport.countInBars, in: 0...4)
                HStack {
                    Text("Volume")
                    Slider(value: $transport.clickGain, in: 0...1)
                }
            }

            Section("Gap click") {
                Toggle("Silent bars", isOn: $transport.gapClickEnabled)
                if transport.gapClickEnabled {
                    Stepper("Bars on: \(transport.gapBarsOn)", value: $transport.gapBarsOn, in: 1...8)
                    Stepper("Bars off: \(transport.gapBarsOff)", value: $transport.gapBarsOff, in: 1...8)
                }
            }

            Section("Target") {
                HStack {
                    Text("Offset")
                    Slider(value: $transport.targetOffsetMs, in: -40...40, step: 1)
                    Text("\(Int(transport.targetOffsetMs)) ms")
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                }
                Text(targetDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Skill target", selection: $transport.targetLevel) {
                    ForEach(TargetLevel.allCases) { level in
                        Text(level.displayName).tag(Optional(level))
                    }
                    Divider()
                    Text("Custom").tag(TargetLevel?.none)
                }
                if transport.targetLevel == nil {
                    Picker("Tolerance", selection: $transport.customToleranceMs) {
                        ForEach([5.0, 10, 15, 20, 30], id: \.self) { tolerance in
                            Text("±\(Int(tolerance)) ms").tag(tolerance)
                        }
                    }
                }
                Text(toleranceCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Expect a note on every slot", isOn: $transport.expectEverySlot)
                if !transport.expectEverySlot {
                    Text("Empty slots are not counted as missed — for patterns with rests.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Monitoring & recording") {
                Toggle("Hear guitar (through app)", isOn: $transport.monitorEnabled)
                if transport.monitorEnabled {
                    HStack {
                        Text("Level")
                        Slider(value: $transport.monitorGain, in: 0...1.5)
                    }
                    Text("Monitoring stays on while the metronome is stopped.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Record session audio", isOn: $transport.recordAudio)
                    .disabled(transport.isRunning)
            }
        }
        .formStyle(.grouped)
        .disabled(false)
    }

    private var toleranceCaption: String {
        let ms = Int(transport.toleranceMs.rounded())
        if transport.isRunning { return "Window ±\(ms) ms — locked for this take" }
        guard transport.targetLevel != nil else { return "Window ±\(ms) ms — fixed, ignores tempo" }
        return "Window ±\(ms) ms at \(Int(transport.bpm)) BPM · \(transport.subdivision.displayName) grid"
    }

    private var targetDescription: String {
        if transport.targetOffsetMs > 0 {
            "Practice playing \(Int(transport.targetOffsetMs)) ms behind the beat"
        } else if transport.targetOffsetMs < 0 {
            "Practice playing \(Int(-transport.targetOffsetMs)) ms ahead of the beat"
        } else {
            "Practice playing dead on the grid"
        }
    }

    // MARK: - Right column

    private var header: some View {
        HStack {
            Button {
                transport.isRunning ? transport.stop() : transport.start()
            } label: {
                Label(
                    transport.isRunning ? "Stop" : "Start",
                    systemImage: transport.isRunning ? "stop.fill" : "play.fill"
                )
                .frame(width: 110)
            }
            .controlSize(.large)
            .keyboardShortcut(.space, modifiers: [])
            .tint(transport.isRunning ? .red : .green)
            .buttonStyle(.borderedProminent)

            if transport.isRunning, let start = transport.sessionStart {
                Text(start, style: .timer)
                    .font(.title2.monospacedDigit())
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(latencyLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = transport.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var latencyLine: String {
        let model = transport.latencyModel
        let ms = model.netCompensationMs(sampleRate: transport.sampleRate)
        let source = model.usesCalibration ? "calibrated" : "reported (calibrate for accuracy!)"
        return String(format: "Latency compensation: %.2f ms — %@", ms, source)
    }

    private var statsRow: some View {
        let stats = transport.snapshot
        let canRate = stats.slotIOIMs > 0 && stats.hitCount >= 2
        // While running, the SD tile is entirely rolling-window (number,
        // tier, and title all describe what you are playing NOW); once
        // stopped it is entirely whole-session, matching the summary sheet
        // and history. Never mix the two metrics in one tile.
        let showRolling = transport.isRunning && stats.rollingSdMs != nil
        let sdShown = showRolling ? (stats.rollingSdMs ?? stats.sdMs) : stats.sdMs
        let meanShown = showRolling ? (stats.rollingMeanMs ?? stats.meanMs) : stats.meanMs
        let stabilityTier: TimingTier? = canRate
            ? TierThresholds.stability.tier(forAbsMs: sdShown, slotIOIMs: stats.slotIOIMs)
            : nil
        let accuracyTier: TimingTier? = canRate
            ? TierThresholds.accuracy.tier(forAbsMs: abs(meanShown), slotIOIMs: stats.slotIOIMs)
            : nil
        return HStack(spacing: 12) {
            StatBox(
                title: showRolling
                    ? "MEAN (last \(min(stats.hitCount, RollingStats.windowHits)))"
                    : "MEAN (bias)",
                value: String(format: "%+.1f ms", meanShown),
                detail: biasDetail(stats, tier: accuracyTier, meanShown: meanShown, showRolling: showRolling),
                color: accuracyTier?.color ?? .primary
            )
            StatBox(
                title: showRolling
                    ? "SD (last \(min(stats.hitCount, RollingStats.windowHits)))"
                    : "SD (stability)",
                value: String(format: "%.1f ms", sdShown),
                detail: stabilityDetail(stats, tier: stabilityTier, showRolling: showRolling),
                color: stabilityTier?.color ?? .primary
            )
            StatBox(
                title: "IN ±\(Int(transport.toleranceMs.rounded())) MS",
                value: String(format: "%.0f%%", stats.pctInTolerance),
                detail: "\(stats.hitCount) hits · \(stats.missedCount) missed · \(stats.extraCount) extra",
                color: .primary
            )
            StatBox(
                title: "DRIFT",
                value: String(format: "%+.1f ms/min", stats.driftMsPerMin),
                detail: driftLabel(stats.driftMsPerMin),
                color: abs(stats.driftMsPerMin) < 5 ? .green : .orange
            )
            StatBox(
                title: "MIN / MAX",
                value: String(format: "%+.0f / %+.0f", stats.minMs, stats.maxMs),
                detail: "range \(String(format: "%.0f ms", stats.maxMs - stats.minMs))",
                color: .primary
            )
        }
    }

    private func biasLabel(_ mean: Double) -> String {
        if abs(mean) < 3 { return "on the grid" }
        return mean > 0 ? "behind the beat" : "ahead of the beat"
    }

    private func stabilityDetail(_ stats: LiveStatsSnapshot, tier: TimingTier?, showRolling: Bool) -> String {
        guard let tier else { return "—" }
        guard showRolling else { return tier.label }
        return String(format: "%@ · session %.1f ms", tier.label, stats.sdMs)
    }

    /// Mirror of `stabilityDetail` for the bias tile: whole-session keeps the
    /// human bias label; while rolling, show the session mean small like SD.
    private func biasDetail(_ stats: LiveStatsSnapshot, tier: TimingTier?,
                            meanShown: Double, showRolling: Bool) -> String {
        guard let tier else { return biasLabel(meanShown) }
        guard showRolling else { return "\(tier.label) · \(biasLabel(meanShown))" }
        return String(format: "%@ · session %+.1f ms", tier.label, stats.meanMs)
    }

    private func driftLabel(_ drift: Double) -> String {
        if abs(drift) < 5 { return "steady" }
        return drift > 0 ? "slowing down" : "rushing"
    }

    /// The running session's grid interval; between sessions, what the
    /// current settings would produce.
    private var liveSlotIOIMs: Double {
        let fromSession = transport.snapshot.slotIOIMs
        guard fromSession > 0 else {
            return TimingRating.slotIOIMs(bpm: transport.bpm, subdivision: transport.subdivision)
        }
        return fromSession
    }
}

/// Live rolling mean/SD charts. A separate child view over plain values so
/// the 50 ms snapshot poll doesn't re-render the Charts — `liveHits` is
/// reassigned only when a hit lands, and this is the perf boundary.
private struct LiveRollingChartsView: View {
    let hits: [Hit]
    let sampleRate: Double
    let slotIOIMs: Double
    let isRunning: Bool

    /// Live window width, in grid slots — matches the hits scatter's
    /// `suffix(200)` so both live charts scroll over the same recent span.
    private static let liveWindowHits = 200

    var body: some View {
        let points = sampleRate > 0
            ? RollingStats.windowedSD(
                timesSec: hits.map { $0.onsetSample / sampleRate },
                deviationsMs: hits.map(\.deviationMs)
            )
            : []
        // While recording, scroll a *fixed-width* time window pinned to the
        // newest point. A fixed X domain (not auto-fit to the visible points)
        // keeps the horizontal scale constant, so the line slides smoothly
        // instead of the whole plot restretching each hit. After stop, the
        // window is nil → the chart auto-fits the whole take, like History.
        let window = liveWindow(points)
        let visible = window?.points ?? points
        HStack(spacing: 12) {
            if visible.isEmpty || slotIOIMs <= 0 {
                Text("Rolling mean/SD charts appear after \(RollingStats.windowHits) hits")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            } else {
                labeledChart(.mean, "Bias — mean of last \(RollingStats.windowHits)", visible, window?.domain)
                labeledChart(.sd, "Stability — SD of last \(RollingStats.windowHits)", visible, window?.domain)
            }
        }
    }

    /// The trailing time window shown while recording: a fixed span of
    /// `liveWindowHits` slots ending at the newest point, plus the points
    /// inside it. `nil` when stopped (show the whole take) or too few points —
    /// the domain left edge holds at the first point until the take outgrows
    /// the span, so early on the chart fills rather than scrolling.
    private func liveWindow(_ points: [RollingPoint])
        -> (points: [RollingPoint], domain: ClosedRange<Double>)? {
        guard isRunning, points.count >= 2, slotIOIMs > 0 else { return nil }
        let last = points[points.count - 1].timeSec
        let span = Double(Self.liveWindowHits) * slotIOIMs / 1000
        let left = max(points[0].timeSec, last - span)
        guard last > left else { return nil }
        return (points.filter { $0.timeSec >= left }, left...last)
    }

    private func labeledChart(_ metric: RollingMetric, _ title: String,
                              _ points: [RollingPoint],
                              _ xDomain: ClosedRange<Double>?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            RollingStatChart(points: points, slotIOIMs: slotIOIMs, metric: metric, xDomain: xDomain)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Session title above the Start button — the native macOS inline-edit
/// pattern: a borderless text field styled as a label. Click puts the cursor
/// in place, hover hints editability, Enter/click-away commits, Esc reverts.
/// Empty shows the "Untitled" prompt and keeps sessions stored unnamed, so
/// history falls back to date + metadata; a custom name persists as the
/// default for the next launch.
private struct SessionNameField: View {
    @Environment(TransportController.self) private var transport
    @State private var draft = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    private static let placeholder = "Untitled"

    var body: some View {
        HStack {
            TextField(Self.placeholder, text: $draft)
                .textFieldStyle(.plain)
                .font(.title2.weight(.semibold))
                .fixedSize()
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(hovering || focused ? Color.primary.opacity(0.07) : .clear)
                )
                .onHover { hovering = $0 }
                .focused($focused)
                .onAppear {
                    draft = transport.sessionName
                    // The window hands initial focus to its first focusable
                    // control — this field. Give it back so Space keeps
                    // driving Start/Stop until the user clicks the title.
                    DispatchQueue.main.async { focused = false }
                }
                .onSubmit { focused = false }
                .onExitCommand {
                    draft = transport.sessionName
                    focused = false
                }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { commit() }
                }
                .onChange(of: transport.sessionName) { _, newValue in
                    if !focused { draft = newValue }
                }
            Spacer()
        }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        transport.sessionName = trimmed == Self.placeholder ? "" : trimmed
        draft = transport.sessionName
    }
}

struct StatBox: View {
    let title: String
    let value: String
    let detail: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(color)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Per-hit deviation timeline: x = hit order, y = deviation (early above,
/// late below zero would be ambiguous — we use standard "late = up").
struct DeviationScatterView: View {
    let hits: [Hit]
    let toleranceMs: Double
    /// Y-range: ±50 ms, widened (to the next 10) when the tolerance band
    /// would not fit — e.g. Beginner windows reach ±60 ms.
    private var rangeMs: Double {
        max(50, (toleranceMs * 1.25 / 10).rounded(.up) * 10)
    }

    var body: some View {
        let range = rangeMs
        Canvas { context, size in
            let midY = size.height / 2
            func y(forMs ms: Double) -> CGFloat {
                midY - CGFloat(ms.clamped(to: -range...range) / range) * (size.height / 2 - 8)
            }

            // Tolerance band.
            let bandTop = y(forMs: toleranceMs)
            let bandBottom = y(forMs: -toleranceMs)
            context.fill(
                Path(CGRect(x: 0, y: bandTop, width: size.width, height: bandBottom - bandTop)),
                with: .color(.green.opacity(0.08))
            )
            // Center line = the target (grid or intentional offset).
            context.stroke(
                Path { $0.move(to: CGPoint(x: 0, y: midY)); $0.addLine(to: CGPoint(x: size.width, y: midY)) },
                with: .color(.secondary.opacity(0.6)), lineWidth: 1
            )
            for ms in [toleranceMs, -toleranceMs] {
                let lineY = y(forMs: ms)
                context.stroke(
                    Path { $0.move(to: CGPoint(x: 0, y: lineY)); $0.addLine(to: CGPoint(x: size.width, y: lineY)) },
                    with: .color(.green.opacity(0.35)), lineWidth: 0.5
                )
            }

            let visible = hits.suffix(200)
            guard !visible.isEmpty else {
                return
            }
            let stepX = size.width / CGFloat(max(visible.count, 40))
            for (index, hit) in visible.enumerated() {
                let x = CGFloat(index) * stepX + stepX / 2
                let pointY = y(forMs: hit.deviationMs)
                let inTolerance = abs(hit.deviationMs) <= toleranceMs
                let color: Color = inTolerance ? .green : (hit.deviationMs < 0 ? .orange : .purple)
                let radius: CGFloat = inTolerance ? 3 : 4
                context.fill(
                    Path(ellipseIn: CGRect(x: x - radius, y: pointY - radius, width: radius * 2, height: radius * 2)),
                    with: .color(color)
                )
            }
        }
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .topLeading) {
            Text("← early · +\(Int(rangeMs)) ms")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(6)
        }
        .overlay(alignment: .bottomLeading) {
            Text("−\(Int(rangeMs)) ms · orange = early, purple = late")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(6)
        }
    }
}

struct HistogramView: View {
    let histogram: [Int]
    let toleranceMs: Double

    var body: some View {
        Canvas { context, size in
            let maxCount = max(histogram.max() ?? 1, 1)
            let barWidth = size.width / CGFloat(histogram.count)
            let center = size.width / 2

            let tolX = CGFloat(toleranceMs / Histogram.rangeMs) * (size.width / 2)
            context.fill(
                Path(CGRect(x: center - tolX, y: 0, width: tolX * 2, height: size.height)),
                with: .color(.green.opacity(0.08))
            )
            context.stroke(
                Path { $0.move(to: CGPoint(x: center, y: 0)); $0.addLine(to: CGPoint(x: center, y: size.height)) },
                with: .color(.secondary.opacity(0.6)), lineWidth: 1
            )
            for (bin, count) in histogram.enumerated() where count > 0 {
                let height = CGFloat(count) / CGFloat(maxCount) * (size.height - 14)
                let centerMs = Histogram.centerMs(ofBin: bin)
                let inTolerance = abs(centerMs) <= toleranceMs
                context.fill(
                    Path(CGRect(x: CGFloat(bin) * barWidth, y: size.height - height,
                                width: max(barWidth - 0.5, 0.5), height: height)),
                    with: .color(inTolerance ? .green : (centerMs < 0 ? .orange : .purple))
                )
            }
        }
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .topLeading) {
            Text("distribution ±\(Int(Histogram.rangeMs)) ms")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(6)
        }
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

extension SessionRecord {
    var subtitle: String {
        let sub = Subdivision(rawValue: subdivision)?.displayName ?? subdivision
        var parts = ["\(Int(bpm)) BPM \(sub)"]
        switch ClickDensity(rawValue: clickDensity) {
        case .beatsOnly:
            parts.append(beatsPerBar.map { "click on beats (\($0)/bar)" } ?? "click on beats")
        case .downbeatsOnly:
            parts.append(beatsPerBar.map { "click on bars (\($0) beats)" } ?? "click on bars")
        default: break
        }
        if let gap = gapPattern { parts.append("gap \(gap)") }
        if targetOffsetMs != 0 { parts.append(String(format: "target %+d ms", Int(targetOffsetMs))) }
        if expectEverySlot == false { parts.append("rests allowed") }
        return parts.joined(separator: " · ")
    }
}
