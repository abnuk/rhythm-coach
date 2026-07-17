import Foundation

/// Visible window into a take: pure sample↔point mapping with zoom/pan.
/// `samplesPerPoint` shrinks as you zoom in; `offsetSamples` is the sample
/// at the left edge. All mutations keep the window inside the take.
public struct WaveformViewport: Sendable, Equatable {
    public var samplesPerPoint: Double
    public var offsetSamples: Double
    public var widthPoints: Double
    public var totalSamples: Double

    public init(samplesPerPoint: Double = 1, offsetSamples: Double = 0,
                widthPoints: Double = 0, totalSamples: Double = 0) {
        self.samplesPerPoint = samplesPerPoint
        self.offsetSamples = offsetSamples
        self.widthPoints = widthPoints
        self.totalSamples = totalSamples
        clamp()
    }

    /// Zoom level at which the whole take exactly fills the view.
    public var fitSamplesPerPoint: Double {
        totalSamples / Swift.max(widthPoints, 1)
    }

    /// Deepest allowed zoom: half a sample per point (or the fit level for
    /// takes shorter than the view).
    public var minSamplesPerPoint: Double {
        Swift.min(0.5, fitSamplesPerPoint)
    }

    public func x(ofSample sample: Double) -> Double {
        (sample - offsetSamples) / samplesPerPoint
    }

    public func sample(atX x: Double) -> Double {
        offsetSamples + x * samplesPerPoint
    }

    public var visibleSampleRange: ClosedRange<Double> {
        offsetSamples...(offsetSamples + widthPoints * samplesPerPoint)
    }

    public mutating func clamp() {
        guard totalSamples > 0, widthPoints > 0 else { return }
        samplesPerPoint = Swift.min(Swift.max(samplesPerPoint, minSamplesPerPoint), fitSamplesPerPoint)
        offsetSamples = Swift.min(Swift.max(offsetSamples, 0), totalSamples - widthPoints * samplesPerPoint)
    }

    /// Zooms by `factor` (>1 zooms out) keeping the sample under `anchorX`
    /// stationary, unless clamping at an edge forces it to move.
    public mutating func zoom(by factor: Double, anchorX: Double) {
        guard factor > 0 else { return }
        let anchor = sample(atX: anchorX)
        samplesPerPoint *= factor
        if totalSamples > 0, widthPoints > 0 {
            samplesPerPoint = Swift.min(Swift.max(samplesPerPoint, minSamplesPerPoint), fitSamplesPerPoint)
        }
        offsetSamples = anchor - anchorX * samplesPerPoint
        clamp()
    }

    public mutating func pan(byPoints deltaPoints: Double) {
        offsetSamples += deltaPoints * samplesPerPoint
        clamp()
    }

    public mutating func fit() {
        samplesPerPoint = fitSamplesPerPoint
        offsetSamples = 0
        clamp()
    }

    /// Continuous follow: keeps `sample` anchored at `anchorFraction` of the
    /// view width (the playhead stays put while the waveform scrolls under
    /// it), clamped to the take — so the anchor releases naturally at both
    /// ends. Returns true iff the offset actually changed.
    public mutating func follow(sample: Double, anchorFraction: Double = 1.0 / 3.0) -> Bool {
        guard totalSamples > 0, widthPoints > 0 else { return false }
        let old = offsetSamples
        offsetSamples = sample - widthPoints * anchorFraction * samplesPerPoint
        clamp()
        return offsetSamples != old
    }
}

/// Metronome grid geometry in the raw WAV sample domain (uncompensated
/// timeline, sample 0 = first count-in slot). `originOffsetSamples` folds in
/// the target offset and the latency compensation so a perfectly timed note
/// lands exactly on its slot line in the recording.
public struct WaveformGridModel: Sendable {
    public enum LineKind: Sendable, Equatable {
        case downbeat
        case beat
        case subdivision
    }

    public var samplesPerSlot: Double
    public var slotsPerBeat: Int
    /// nil when unknown (old sessions): no downbeat emphasis.
    public var beatsPerBar: Int?
    /// nil when unknown (old sessions): no count-in shading.
    public var countInSlots: Int?
    public var originOffsetSamples: Double
    public var totalSamples: Double

    public init(samplesPerSlot: Double, slotsPerBeat: Int,
                beatsPerBar: Int? = nil, countInSlots: Int? = nil,
                originOffsetSamples: Double = 0, totalSamples: Double = 0) {
        self.samplesPerSlot = samplesPerSlot
        self.slotsPerBeat = slotsPerBeat
        self.beatsPerBar = beatsPerBar
        self.countInSlots = countInSlots
        self.originOffsetSamples = originOffsetSamples
        self.totalSamples = totalSamples
    }

    public func wavSample(ofSlot index: Int) -> Double {
        Double(index) * samplesPerSlot + originOffsetSamples
    }

    /// Slots whose grid line falls inside both the viewport and the take.
    public func visibleSlots(in viewport: WaveformViewport) -> ClosedRange<Int>? {
        guard samplesPerSlot > 0 else { return nil }
        let visible = viewport.visibleSampleRange
        let lowSample = Swift.max(visible.lowerBound, 0)
        let highSample = Swift.min(visible.upperBound, totalSamples)
        let low = Int(((lowSample - originOffsetSamples) / samplesPerSlot).rounded(.up))
        let high = Int(((highSample - originOffsetSamples) / samplesPerSlot).rounded(.down))
        let first = Swift.max(low, 0)
        guard first <= high else { return nil }
        return first...high
    }

    public func kind(ofSlot index: Int) -> LineKind {
        if let beatsPerBar {
            let slotsPerBar = beatsPerBar * slotsPerBeat
            let inBar = ((index % slotsPerBar) + slotsPerBar) % slotsPerBar
            if inBar == 0 { return .downbeat }
            return inBar % slotsPerBeat == 0 ? .beat : .subdivision
        }
        return index % slotsPerBeat == 0 ? .beat : .subdivision
    }
}
