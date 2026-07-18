import Foundation

/// Immutable snapshot of session statistics for UI display.
public struct LiveStatsSnapshot: Sendable, Equatable {
    public var hitCount: Int = 0
    public var missedCount: Int = 0
    public var extraCount: Int = 0
    /// Mean signed asynchrony in ms (+ late / - early). The bias.
    public var meanMs: Double = 0
    /// Standard deviation of asynchrony in ms. The stability.
    public var sdMs: Double = 0
    public var minMs: Double = 0
    public var maxMs: Double = 0
    public var pctInTolerance: Double = 0
    /// Tempo pull: linear regression slope of deviation vs time, ms/min.
    /// Positive = progressively later (dragging), negative = rushing.
    public var driftMsPerMin: Double = 0
    /// Lag-1 autocorrelation of deviations (error-correction indicator).
    public var lag1: Double = 0
    public var toleranceMs: Double = 15
    /// Interval of the analysis-grid slot in ms; 0 = unknown grid.
    public var slotIOIMs: Double = 0
    /// Sample SD of the most recent `RollingStats.windowHits` deviations;
    /// nil until `RollingStats.minLiveHits` hits have been scored.
    public var rollingSdMs: Double? = nil
    /// Signed mean of the most recent `RollingStats.windowHits` deviations;
    /// nil until `RollingStats.minLiveHits` hits (parallel to `rollingSdMs`).
    public var rollingMeanMs: Double? = nil
    /// Histogram of deviations, `Histogram.binCount` bins over ±`Histogram.rangeMs`.
    public var histogram: [Int] = Array(repeating: 0, count: Histogram.binCount)

    public init() {}
}

public extension LiveStatsSnapshot {
    /// Tempo-normalized whole-session rating; nil below 2 hits or without a grid.
    var rating: TimingRating? {
        TimingRating(sdMs: sdMs, meanMs: meanMs, slotIOIMs: slotIOIMs, hitCount: hitCount)
    }
}

public enum Histogram {
    public static let rangeMs: Double = 100
    public static let binWidthMs: Double = 2
    public static let binCount = Int(rangeMs * 2 / binWidthMs)

    public static func bin(forDeviationMs ms: Double) -> Int {
        let idx = Int(floor((ms + rangeMs) / binWidthMs))
        return min(max(idx, 0), binCount - 1)
    }

    public static func centerMs(ofBin index: Int) -> Double {
        Double(index) * binWidthMs - rangeMs + binWidthMs / 2
    }
}

/// Online statistics over scored events (Welford mean/variance, extrema,
/// tolerance rate, drift regression, lag-1 autocorrelation, histogram).
/// Owned by the analysis thread.
public final class StatsAccumulator {
    public let toleranceMs: Double
    private let sampleRate: Double
    private let slotIOIMs: Double

    private var count = 0
    private var mean = 0.0
    private var m2 = 0.0
    private var minMs = Double.infinity
    private var maxMs = -Double.infinity
    private var inTolerance = 0
    private var missed = 0
    private var extra = 0
    private var histogram = [Int](repeating: 0, count: Histogram.binCount)
    private var deviations: [Double] = []

    // Least squares of deviation (ms) vs onset time (minutes).
    private var sumX = 0.0, sumY = 0.0, sumXY = 0.0, sumXX = 0.0

    public init(toleranceMs: Double, sampleRate: Double, slotIOIMs: Double = 0) {
        self.toleranceMs = toleranceMs
        self.sampleRate = sampleRate
        self.slotIOIMs = slotIOIMs
        deviations.reserveCapacity(4096)
    }

    public func add(_ event: ScoredEvent) {
        switch event {
        case .hit(let hit):
            let d = hit.deviationMs
            count += 1
            let delta = d - mean
            mean += delta / Double(count)
            m2 += delta * (d - mean)
            minMs = Swift.min(minMs, d)
            maxMs = Swift.max(maxMs, d)
            if abs(d) <= toleranceMs { inTolerance += 1 }
            histogram[Histogram.bin(forDeviationMs: d)] += 1
            deviations.append(d)
            let minutes = hit.onsetSample / sampleRate / 60
            sumX += minutes
            sumY += d
            sumXY += minutes * d
            sumXX += minutes * minutes
        case .missed:
            missed += 1
        case .extra:
            extra += 1
        }
    }

    public func snapshot() -> LiveStatsSnapshot {
        var s = LiveStatsSnapshot()
        s.hitCount = count
        s.missedCount = missed
        s.extraCount = extra
        s.toleranceMs = toleranceMs
        s.slotIOIMs = slotIOIMs
        s.histogram = histogram
        guard count > 0 else { return s }
        s.meanMs = mean
        s.sdMs = count > 1 ? (m2 / Double(count - 1)).squareRoot() : 0
        s.minMs = minMs
        s.maxMs = maxMs
        s.pctInTolerance = Double(inTolerance) / Double(count) * 100
        if count >= RollingStats.minLiveHits {
            let recent = deviations.suffix(RollingStats.windowHits)
            var rMean = 0.0
            for d in recent { rMean += d }
            rMean /= Double(recent.count)
            var rM2 = 0.0
            for d in recent { rM2 += (d - rMean) * (d - rMean) }
            s.rollingMeanMs = rMean
            s.rollingSdMs = (rM2 / Double(recent.count - 1)).squareRoot()
        }

        if count > 2 {
            let n = Double(count)
            let denom = n * sumXX - sumX * sumX
            if abs(denom) > 1e-12 {
                s.driftMsPerMin = (n * sumXY - sumX * sumY) / denom
            }
            var num = 0.0
            var den = 0.0
            for i in 0..<count {
                let a = deviations[i] - mean
                den += a * a
                if i + 1 < count {
                    num += a * (deviations[i + 1] - mean)
                }
            }
            if den > 1e-12 { s.lag1 = num / den }
        }
        return s
    }
}
