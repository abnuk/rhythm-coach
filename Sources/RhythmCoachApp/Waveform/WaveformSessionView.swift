import RhythmCore
import SwiftUI

/// A detected hit in the raw WAV sample domain: `onsetWavSample` is the exact
/// audio moment the scorer used for this hit's deviation.
struct WaveformHitMarker: Identifiable, Sendable {
    let id: Int
    let slotIndex: Int
    let deviationMs: Double
    let onsetWavSample: Double

    /// Persisted rows (History). `HitRow.onsetSample` is latency-compensated;
    /// adding the compensation back lands on the recorded audio.
    static func markers(rows: [HitRow], record: SessionRecord) -> [WaveformHitMarker] {
        let latencySamples = record.latencyCompMs / 1000 * record.sampleRate
        return rows.enumerated().compactMap { index, row in
            guard row.kind == "hit" else { return nil }
            return WaveformHitMarker(id: index, slotIndex: row.slotIndex,
                                     deviationMs: row.deviationMs,
                                     onsetWavSample: row.onsetSample + latencySamples)
        }
    }

    /// Live results (Practice, after stop). Same compensated timeline as rows.
    static func markers(hits: [Hit], record: SessionRecord) -> [WaveformHitMarker] {
        let latencySamples = record.latencyCompMs / 1000 * record.sampleRate
        return hits.enumerated().map { index, hit in
            WaveformHitMarker(id: index, slotIndex: hit.slotIndex,
                              deviationMs: hit.deviationMs,
                              onsetWavSample: hit.onsetSample + latencySamples)
        }
    }
}

/// Grid overlay parameters in session-record units.
struct WaveformGridParams: Sendable, Equatable {
    var bpm: Double
    var slotsPerBeat: Int
    var beatsPerBar: Int?
    var countInBars: Int?
    var targetOffsetMs: Double
    var latencyCompMs: Double
    var toleranceMs: Double
    var sampleRate: Double

    init(record: SessionRecord) {
        bpm = record.bpm
        slotsPerBeat = Subdivision(rawValue: record.subdivision)?.slotsPerBeat ?? 1
        beatsPerBar = record.beatsPerBar
        countInBars = record.countInBars
        targetOffsetMs = record.targetOffsetMs
        latencyCompMs = record.latencyCompMs
        toleranceMs = record.toleranceMs
        sampleRate = record.sampleRate
    }

    var samplesPerSlot: Double { sampleRate * 60 / bpm / Double(slotsPerBeat) }

    func gridModel(totalSamples: Double) -> WaveformGridModel {
        WaveformGridModel(
            samplesPerSlot: samplesPerSlot,
            slotsPerBeat: slotsPerBeat,
            beatsPerBar: beatsPerBar,
            countInSlots: beatsPerBar.flatMap { bars in
                countInBars.map { $0 * bars * slotsPerBeat }
            },
            originOffsetSamples: (targetOffsetMs + latencyCompMs) / 1000 * sampleRate,
            totalSamples: totalSamples
        )
    }
}

/// Zoomable, pannable waveform of a recorded take with the metronome grid,
/// one marker per hit at the exact onset the scorer used, and a connector to
/// the slot's reference line showing the deviation.
struct WaveformSessionView: View {
    let audioURL: URL
    /// Click-overlaid mix sharing the input file's timeline; when present the
    /// toolbar offers switching playback between the two.
    let mixURL: URL?
    let grid: WaveformGridParams
    let hits: [WaveformHitMarker]
    /// Owned by the host screen so the same playhead clock drives the
    /// synchronized position markers on the sibling stat charts.
    let playback: WaveformPlaybackController

    private enum Phase {
        case loading
        case ready(WaveformData)
        case unavailable(String)
    }

    @State private var phase: Phase = .loading
    @State private var viewport = WaveformViewport()
    @State private var playMix = false

    init(audioURL: URL, mixURL: URL? = nil, grid: WaveformGridParams,
         hits: [WaveformHitMarker], playback: WaveformPlaybackController) {
        self.audioURL = audioURL
        self.mixURL = mixURL
        self.grid = grid
        self.hits = hits.sorted { $0.onsetWavSample < $1.onsetWavSample }
        self.playback = playback
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch phase {
            case .loading:
                placeholder { ProgressView().controlSize(.small) }
            case .unavailable(let message):
                placeholder {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .ready(let data):
                toolbar
                canvas(data: data)
            }
        }
        .task(id: audioURL) { await load() }
        .onDisappear { playback.stop() }
    }

    private func placeholder(@ViewBuilder content: () -> some View) -> some View {
        ZStack { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                playback.togglePlayPause()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
            }
            .disabled(!playback.isAvailable)
            PlaybackTimeReadout(playback: playback)
            if let mixURL {
                Picker("Playback source", selection: $playMix) {
                    Text("Input").tag(false)
                    Text("With click").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .onChange(of: playMix) { _, mix in
                    playback.switchSource(url: mix ? mixURL : audioURL)
                }
            }
            Divider().frame(height: 12)
            Button {
                viewport.zoom(by: 0.5, anchorX: viewport.widthPoints / 2)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            Button {
                viewport.zoom(by: 2, anchorX: viewport.widthPoints / 2)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            Button("Fit") { viewport.fit() }
            Text(scaleReadout)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
        }
        .controlSize(.small)
    }

    private var scaleReadout: String {
        let visibleSeconds = viewport.widthPoints * viewport.samplesPerPoint / grid.sampleRate
        if visibleSeconds >= 1 {
            return String(format: "%.2f s visible", visibleSeconds)
        }
        return String(format: "%.0f ms visible", visibleSeconds * 1000)
    }

    private func canvas(data: WaveformData) -> some View {
        WaveformCanvasView(data: data, grid: grid, hits: hits, viewport: viewport)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            WaveformPlayheadOverlay(
                playback: playback,
                viewport: viewport,
                sampleRate: data.sampleRate,
                onAutoFollow: { sample in
                    var followed = viewport
                    if followed.follow(sample: sample) { viewport = followed }
                }
            )
        }
        .overlay {
            WaveformInteractionView(
                onPan: { viewport.pan(byPoints: $0) },
                onZoom: { factor, anchorX in viewport.zoom(by: factor, anchorX: anchorX) },
                onSeek: { anchorX in
                    let sample = viewport.sample(atX: anchorX)
                        .clamped(to: 0...Double(data.samples.count))
                    playback.seek(toSample: sample, sampleRate: data.sampleRate)
                }
            )
        }
        .overlay(alignment: .bottomLeading) {
            Text("orange = early, purple = late · click = seek · drag/scroll = pan · ⌥scroll / pinch = zoom")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(6)
                .allowsHitTesting(false)
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            updateWidth(Double(width))
        }
    }

    private func updateWidth(_ width: Double) {
        guard width > 0, width != viewport.widthPoints else { return }
        let wasFit = viewport.widthPoints <= 0
            || abs(viewport.samplesPerPoint - viewport.fitSamplesPerPoint) < 1e-9
        viewport.widthPoints = width
        if wasFit { viewport.fit() } else { viewport.clamp() }
    }

    private func load() async {
        phase = .loading
        playback.stop()
        playMix = false
        let url = audioURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            phase = .unavailable("Recording unavailable")
            return
        }
        let result = await Task.detached(priority: .userInitiated) {
            Result { try WaveformData.load(url: url) }
        }.value
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let data):
            viewport.totalSamples = Double(data.samples.count)
            viewport.fit()
            playback.load(url: url)
            phase = .ready(data)
        case .failure:
            phase = .unavailable("Could not read recording")
        }
    }

}

/// Pure rendering layer: waveform + grid + hit markers for a pre-loaded take
/// at a given viewport. Free of loading/gesture state so it can be rendered
/// headlessly as well as on screen.
struct WaveformCanvasView: View {
    let data: WaveformData
    let grid: WaveformGridParams
    let hits: [WaveformHitMarker]
    let viewport: WaveformViewport

    var body: some View {
        Canvas { context, size in
            draw(context: context, size: size, data: data)
        }
    }

    private func draw(context: GraphicsContext, size: CGSize, data: WaveformData) {
        guard !data.samples.isEmpty, size.width > 0 else { return }
        // Local copy synced to the actual canvas size: the first frame can
        // render before onGeometryChange delivers the width.
        var vp = viewport
        vp.widthPoints = Double(size.width)
        vp.totalSamples = Double(data.samples.count)
        vp.clamp()

        let gridModel = grid.gridModel(totalSamples: Double(data.samples.count))
        drawCountIn(context: context, size: size, viewport: vp, gridModel: gridModel)
        drawGridLines(context: context, size: size, viewport: vp, gridModel: gridModel)
        drawWave(context: context, size: size, viewport: vp, data: data)
        drawHits(context: context, size: size, viewport: vp, gridModel: gridModel)
    }

    private func drawCountIn(context: GraphicsContext, size: CGSize,
                             viewport vp: WaveformViewport, gridModel: WaveformGridModel) {
        guard let countInSlots = gridModel.countInSlots, countInSlots > 0 else { return }
        let startX = max(0, vp.x(ofSample: gridModel.wavSample(ofSlot: 0)))
        let endX = min(Double(size.width), vp.x(ofSample: gridModel.wavSample(ofSlot: countInSlots)))
        guard endX > startX else { return }
        context.fill(
            Path(CGRect(x: startX, y: 0, width: endX - startX, height: size.height)),
            with: .color(.secondary.opacity(0.1))
        )
    }

    private func drawGridLines(context: GraphicsContext, size: CGSize,
                               viewport vp: WaveformViewport, gridModel: WaveformGridModel) {
        guard let slots = gridModel.visibleSlots(in: vp) else { return }
        let pxPerSlot = gridModel.samplesPerSlot / vp.samplesPerPoint
        let pxPerBeat = pxPerSlot * Double(gridModel.slotsPerBeat)
        let minSpacing = 6.0

        // Iterate only the slots that survive culling: multiples of `step`
        // are aligned to slot 0, so they always land on beats/downbeats.
        var step = 1
        if pxPerSlot < minSpacing { step = gridModel.slotsPerBeat }
        if pxPerBeat < minSpacing {
            if let beatsPerBar = gridModel.beatsPerBar {
                let slotsPerBar = beatsPerBar * gridModel.slotsPerBeat
                let pxPerBar = pxPerSlot * Double(slotsPerBar)
                step = slotsPerBar * max(1, Int((minSpacing / pxPerBar).rounded(.up)))
            } else {
                step = gridModel.slotsPerBeat * max(1, Int((minSpacing / pxPerBeat).rounded(.up)))
            }
        }

        var subdivisionPath = Path()
        var beatPath = Path()
        var downbeatPath = Path()
        var slot = ((slots.lowerBound + step - 1) / step) * step
        while slot <= slots.upperBound {
            let x = vp.x(ofSample: gridModel.wavSample(ofSlot: slot))
            let line = Path {
                $0.move(to: CGPoint(x: x, y: 0))
                $0.addLine(to: CGPoint(x: x, y: size.height))
            }
            switch gridModel.kind(ofSlot: slot) {
            case .downbeat: downbeatPath.addPath(line)
            case .beat: beatPath.addPath(line)
            case .subdivision: subdivisionPath.addPath(line)
            }
            slot += step
        }
        context.stroke(subdivisionPath, with: .color(.secondary.opacity(0.22)), lineWidth: 0.5)
        context.stroke(beatPath, with: .color(.secondary.opacity(0.45)), lineWidth: 1)
        context.stroke(downbeatPath, with: .color(.secondary.opacity(0.7)), lineWidth: 1.5)
    }

    private func drawWave(context: GraphicsContext, size: CGSize,
                          viewport vp: WaveformViewport, data: WaveformData) {
        let midY = size.height / 2
        // Mild auto-gain from the whole-take peak so quiet takes stay visible.
        let peak = data.peaks.levels.last?.first.map { max(abs($0.min), abs($0.max)) } ?? 1
        let gain = (1 / max(Double(peak), 0.05)).clamped(to: 1...20)
        let amp = (midY - 6) * CGFloat(gain)
        let color = Color.accentColor.opacity(0.8)

        if vp.samplesPerPoint < 1 {
            let first = max(0, Int(vp.offsetSamples.rounded(.down)))
            let last = min(data.samples.count - 1,
                           Int((vp.offsetSamples + Double(size.width) * vp.samplesPerPoint).rounded(.up)))
            guard first <= last else { return }
            var path = Path()
            for i in first...last {
                let point = CGPoint(x: vp.x(ofSample: Double(i)),
                                    y: midY - CGFloat(data.samples[i]) * amp)
                i == first ? path.move(to: point) : path.addLine(to: point)
            }
            context.stroke(path, with: .color(color), lineWidth: 1)
        } else {
            let columns = Int(size.width.rounded(.up))
            let buckets = data.columnMinMax(startSample: vp.offsetSamples,
                                            samplesPerPoint: vp.samplesPerPoint,
                                            columns: columns)
            var path = Path()
            for (column, bucket) in buckets.enumerated() {
                let x = CGFloat(column) + 0.5
                let top = midY - CGFloat(bucket.max) * amp
                let bottom = midY - CGFloat(bucket.min) * amp
                path.move(to: CGPoint(x: x, y: top))
                path.addLine(to: CGPoint(x: x, y: max(bottom, top + 1)))
            }
            context.stroke(path, with: .color(color), lineWidth: 1)
        }
    }

    private func drawHits(context: GraphicsContext, size: CGSize,
                          viewport vp: WaveformViewport, gridModel: WaveformGridModel) {
        guard !hits.isEmpty else { return }
        let visible = vp.visibleSampleRange
        let marginSamples = 80 * vp.samplesPerPoint
        let pxPerSlot = gridModel.samplesPerSlot / vp.samplesPerPoint
        let showLabels = pxPerSlot >= 60
        let laneY: CGFloat = 14

        // Hits are sorted by onset; binary-search the first visible one.
        var low = 0
        var high = hits.count
        while low < high {
            let mid = (low + high) / 2
            if hits[mid].onsetWavSample < visible.lowerBound - marginSamples {
                low = mid + 1
            } else {
                high = mid
            }
        }

        for hit in hits[low...] {
            if hit.onsetWavSample > visible.upperBound + marginSamples { break }
            let x = vp.x(ofSample: hit.onsetWavSample)
            let referenceX = vp.x(ofSample: gridModel.wavSample(ofSlot: hit.slotIndex))
            let inTolerance = abs(hit.deviationMs) <= grid.toleranceMs
            let color: Color = inTolerance ? .green : (hit.deviationMs < 0 ? .orange : .purple)

            context.stroke(
                Path {
                    $0.move(to: CGPoint(x: x, y: 0))
                    $0.addLine(to: CGPoint(x: x, y: size.height))
                },
                with: .color(color.opacity(0.85)), lineWidth: 1.5
            )
            var triangle = Path()
            triangle.move(to: CGPoint(x: x - 4, y: 0))
            triangle.addLine(to: CGPoint(x: x + 4, y: 0))
            triangle.addLine(to: CGPoint(x: x, y: 7))
            triangle.closeSubpath()
            context.fill(triangle, with: .color(color))

            // Deviation connector: onset marker ↔ the slot's reference line.
            if abs(referenceX - x) >= 2 {
                context.stroke(
                    Path {
                        $0.move(to: CGPoint(x: referenceX, y: laneY))
                        $0.addLine(to: CGPoint(x: x, y: laneY))
                    },
                    with: .color(color.opacity(0.9)), lineWidth: 2
                )
                context.stroke(
                    Path {
                        $0.move(to: CGPoint(x: referenceX, y: laneY - 4))
                        $0.addLine(to: CGPoint(x: referenceX, y: laneY + 4))
                    },
                    with: .color(color.opacity(0.9)), lineWidth: 1
                )
            }
            if showLabels {
                context.draw(
                    Text(String(format: "%+.1f", hit.deviationMs))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(color),
                    at: CGPoint(x: (x + referenceX) / 2, y: laneY + 12),
                    anchor: .center
                )
            }
        }
    }
}
