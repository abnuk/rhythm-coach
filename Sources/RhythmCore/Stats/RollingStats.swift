import Foundation

/// One point of a windowed statistic over a session.
public struct RollingPoint: Sendable, Equatable {
    /// Session time of the window's last hit, seconds.
    public let timeSec: Double
    /// Sample SD (n − 1) of the window, consistent with `StatsAccumulator`.
    public let sdMs: Double
    public let meanMs: Double

    public init(timeSec: Double, sdMs: Double, meanMs: Double) {
        self.timeSec = timeSec
        self.sdMs = sdMs
        self.meanMs = meanMs
    }
}

/// Rolling (windowed) statistics over per-hit deviations. Hit-count windows
/// give every point the same statistical confidence regardless of tempo,
/// rests, or gap bars — unlike time windows, whose hit counts vary wildly.
public enum RollingStats {
    /// Window length in hits (≈ four bars of 4/4 quarters).
    public static let windowHits = 16
    /// Realtime feedback starts from a partial window of this many hits.
    public static let minLiveHits = 8

    /// SD/mean of every `window`-hit window, stepping one hit at a time.
    /// `timesSec` and `deviationsMs` must be parallel and time-ordered.
    /// Returns `[]` when there are fewer than `window` samples.
    public static func windowedSD(timesSec: [Double], deviationsMs: [Double],
                                  window: Int = windowHits) -> [RollingPoint] {
        let n = min(timesSec.count, deviationsMs.count)
        guard window >= 2, n >= window else { return [] }
        var points: [RollingPoint] = []
        points.reserveCapacity(n - window + 1)
        for end in window...n {
            let slice = deviationsMs[(end - window)..<end]
            var mean = 0.0
            for d in slice { mean += d }
            mean /= Double(window)
            var m2 = 0.0
            for d in slice { m2 += (d - mean) * (d - mean) }
            points.append(RollingPoint(
                timeSec: timesSec[end - 1],
                sdMs: (m2 / Double(window - 1)).squareRoot(),
                meanMs: mean
            ))
        }
        return points
    }
}
