import Foundation

/// A scored hit: an onset matched to a grid slot.
public struct Hit: Sendable, Equatable {
    public var slotIndex: Int
    public var gridSample: Double     // reference time incl. target offset
    public var onsetSample: Double    // latency-compensated onset time
    public var deviationMs: Double    // + late, - early
    /// Deviation as % of the analysis-grid slot interval (the played IOI).
    public var deviationPctIOI: Double
    public var strength: Float

    public init(slotIndex: Int, gridSample: Double, onsetSample: Double,
                deviationMs: Double, deviationPctIOI: Double, strength: Float) {
        self.slotIndex = slotIndex
        self.gridSample = gridSample
        self.onsetSample = onsetSample
        self.deviationMs = deviationMs
        self.deviationPctIOI = deviationPctIOI
        self.strength = strength
    }
}

/// Events emitted by the scorer.
public enum ScoredEvent: Sendable, Equatable {
    case hit(Hit)
    case missed(slotIndex: Int)
    case extra(onsetSample: Double)
}

/// Matches latency-compensated onsets to the nearest grid slot and scores
/// the signed deviation. Slots during count-in are ignored. In target-offset
/// mode the reference is the grid shifted by `targetOffsetMs`.
///
/// Owned by the analysis thread; not thread-safe.
public final class TimingScorer {
    public let grid: ClickGrid
    /// Total compensation subtracted from raw onset sample times
    /// (round-trip latency + manual driver offset), in samples.
    public let latencyCompensationSamples: Double
    /// Matching window half-width in samples.
    public let windowSamples: Double

    private let targetOffsetSamples: Double
    private var bestHitPerSlot: [Int: Hit] = [:]
    private var reportedMissed: Set<Int> = []
    private var highestFullyPassedSlot: Int = -1

    public init(grid: ClickGrid, latencyCompensationSamples: Double) {
        self.grid = grid
        self.latencyCompensationSamples = latencyCompensationSamples
        self.targetOffsetSamples = grid.spec.targetOffsetMs / 1000 * grid.sampleRate
        self.windowSamples = min(grid.samplesPerSlot / 2, 0.060 * grid.sampleRate)
    }

    /// Reference time for a slot (grid + intentional target offset).
    public func referenceSample(forSlot index: Int) -> Double {
        grid.sampleTime(ofSlot: index) + targetOffsetSamples
    }

    /// Processes one onset; returns the resulting events. The first onset in
    /// a slot's window claims it; later onsets in the same slot are `.extra`
    /// (keeps online statistics one-hit-per-slot consistent).
    public func onOnset(_ onset: Onset) -> [ScoredEvent] {
        let adjusted = onset.sampleTime - latencyCompensationSamples
        let slot = grid.nearestSlot(to: adjusted - targetOffsetSamples)
        guard slot >= grid.countInSlots else { return [] }

        let reference = referenceSample(forSlot: slot)
        let deviationSamples = adjusted - reference
        guard abs(deviationSamples) <= windowSamples, bestHitPerSlot[slot] == nil else {
            return [.extra(onsetSample: adjusted)]
        }

        let deviationMs = deviationSamples / grid.sampleRate * 1000
        let slotMs = grid.samplesPerSlot / grid.sampleRate * 1000
        let hit = Hit(
            slotIndex: slot,
            gridSample: reference,
            onsetSample: adjusted,
            deviationMs: deviationMs,
            deviationPctIOI: deviationMs / slotMs * 100,
            strength: onset.strength
        )
        bestHitPerSlot[slot] = hit
        return [.hit(hit)]
    }

    /// Advances stream time; emits `.missed` for slots whose matching window
    /// has fully passed without a hit. `rawSampleTime` is uncompensated
    /// (same timeline the detector reports in). No-op when the spec does not
    /// expect a note on every slot (patterns with rests).
    public func advance(to rawSampleTime: Double) -> [ScoredEvent] {
        guard grid.spec.expectEverySlot else { return [] }
        let adjusted = rawSampleTime - latencyCompensationSamples
        let lastPassed = Int(floor((adjusted - targetOffsetSamples - windowSamples) / grid.samplesPerSlot))
        guard lastPassed > highestFullyPassedSlot else { return [] }
        var events: [ScoredEvent] = []
        let from = max(highestFullyPassedSlot + 1, grid.countInSlots)
        if from <= lastPassed {
            for slot in from...lastPassed {
                if bestHitPerSlot[slot] == nil && !reportedMissed.contains(slot) {
                    reportedMissed.insert(slot)
                    events.append(.missed(slotIndex: slot))
                }
            }
        }
        highestFullyPassedSlot = lastPassed
        return events
    }

    public var hits: [Hit] {
        bestHitPerSlot.values.sorted { $0.slotIndex < $1.slotIndex }
    }
}
