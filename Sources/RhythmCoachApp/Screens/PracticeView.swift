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
                header
                statsRow
                DeviationScatterView(
                    hits: transport.liveHits,
                    toleranceMs: transport.toleranceMs
                )
                .frame(minHeight: 180)
                HistogramView(histogram: transport.snapshot.histogram, toleranceMs: transport.toleranceMs)
                    .frame(height: 110)
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
                Picker("Grid", selection: $transport.subdivision) {
                    ForEach(Subdivision.allCases) { sub in
                        Text(sub.displayName).tag(sub)
                    }
                }
                .pickerStyle(.segmented)
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
                Picker("Tolerance", selection: $transport.toleranceMs) {
                    ForEach([5.0, 10, 15, 20, 30], id: \.self) { tolerance in
                        Text("±\(Int(tolerance)) ms").tag(tolerance)
                    }
                }
            }

            Section("Monitoring & recording") {
                Toggle("Hear guitar (through app)", isOn: $transport.monitorEnabled)
                if transport.monitorEnabled {
                    HStack {
                        Text("Level")
                        Slider(value: $transport.monitorGain, in: 0...1.5)
                    }
                }
                Toggle("Record session audio", isOn: $transport.recordAudio)
                    .disabled(transport.isRunning)
            }
        }
        .formStyle(.grouped)
        .disabled(false)
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
        return HStack(spacing: 12) {
            StatBox(
                title: "MEAN (bias)",
                value: String(format: "%+.1f ms", stats.meanMs),
                detail: biasLabel(stats.meanMs),
                color: abs(stats.meanMs) <= transport.toleranceMs ? .green : .orange
            )
            StatBox(
                title: "SD (stability)",
                value: String(format: "%.1f ms", stats.sdMs),
                detail: stabilityLabel(stats.sdMs),
                color: stats.sdMs <= 10 ? .green : (stats.sdMs <= 20 ? .yellow : .orange)
            )
            StatBox(
                title: "IN ±\(Int(transport.toleranceMs)) MS",
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

    private func stabilityLabel(_ sd: Double) -> String {
        switch sd {
        case ..<5: "rock solid"
        case ..<10: "tight"
        case ..<20: "loose"
        default: "unstable"
        }
    }

    private func driftLabel(_ drift: Double) -> String {
        if abs(drift) < 5 { return "steady" }
        return drift > 0 ? "slowing down" : "rushing"
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
    private let rangeMs: Double = 50

    var body: some View {
        Canvas { context, size in
            let midY = size.height / 2
            func y(forMs ms: Double) -> CGFloat {
                midY - CGFloat(ms.clamped(to: -rangeMs...rangeMs) / rangeMs) * (size.height / 2 - 8)
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
        if let gap = gapPattern { parts.append("gap \(gap)") }
        if targetOffsetMs != 0 { parts.append(String(format: "target %+d ms", Int(targetOffsetMs))) }
        return parts.joined(separator: " · ")
    }
}
