import Foundation

/// Qualitative timing quality tier, ordered worst → best.
public enum TimingTier: Int, Comparable, CaseIterable, Sendable {
    case poor = 0
    case fair
    case good
    case pro

    public var label: String {
        switch self {
        case .poor: "poor"
        case .fair: "fair"
        case .good: "good"
        case .pro: "pro"
        }
    }

    public static func < (lhs: TimingTier, rhs: TimingTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Hybrid Weber-law tier boundaries: a value earns a tier when it is within
/// `max(absolute floor, fraction × played IOI)`. Perceived timing error
/// scales with the inter-onset interval above ~250 ms and bottoms out at a
/// constant floor below it (Friberg & Sundberg 1995: JND ≈ max(10 ms, 5%));
/// elite drummers hold SD around 3-4% of the IOI. Boundaries are inclusive
/// toward the better tier.
///
/// These constants are the single source of truth — no other code may carry
/// numeric tier thresholds.
public struct TierThresholds: Sendable {
    public let proFloorMs: Double
    public let proFracIOI: Double
    public let goodFloorMs: Double
    public let goodFracIOI: Double
    public let fairFloorMs: Double
    public let fairFracIOI: Double

    public init(pro: (floorMs: Double, fracIOI: Double),
                good: (floorMs: Double, fracIOI: Double),
                fair: (floorMs: Double, fracIOI: Double)) {
        self.proFloorMs = pro.floorMs
        self.proFracIOI = pro.fracIOI
        self.goodFloorMs = good.floorMs
        self.goodFracIOI = good.fracIOI
        self.fairFloorMs = fair.floorMs
        self.fairFracIOI = fair.fracIOI
    }

    /// Boundary of the pro tier in ms for a given slot interval.
    public func proLimitMs(slotIOIMs: Double) -> Double {
        max(proFloorMs, proFracIOI * slotIOIMs)
    }

    public func goodLimitMs(slotIOIMs: Double) -> Double {
        max(goodFloorMs, goodFracIOI * slotIOIMs)
    }

    public func fairLimitMs(slotIOIMs: Double) -> Double {
        max(fairFloorMs, fairFracIOI * slotIOIMs)
    }

    public func tier(forAbsMs value: Double, slotIOIMs: Double) -> TimingTier {
        if value <= proLimitMs(slotIOIMs: slotIOIMs) { return .pro }
        if value <= goodLimitMs(slotIOIMs: slotIOIMs) { return .good }
        if value <= fairLimitMs(slotIOIMs: slotIOIMs) { return .fair }
        return .poor
    }

    /// SD of deviations (stability).
    public static let stability = TierThresholds(pro: (8, 0.03), good: (12, 0.05), fair: (20, 0.08))
    /// |mean| offset (accuracy) — held tighter than stability.
    public static let accuracy = TierThresholds(pro: (5, 0.02), good: (10, 0.04), fair: (15, 0.06))
}

/// Tempo-normalized quality rating of a take or session.
public struct TimingRating: Sendable, Equatable {
    public let stability: TimingTier
    public let accuracy: TimingTier
    public let overall: TimingTier

    /// nil when SD is undefined (fewer than 2 hits) or the grid is unknown.
    public init?(sdMs: Double, meanMs: Double, slotIOIMs: Double, hitCount: Int) {
        guard hitCount >= 2, slotIOIMs > 0 else { return nil }
        let stability = TierThresholds.stability.tier(forAbsMs: sdMs, slotIOIMs: slotIOIMs)
        let accuracy = TierThresholds.accuracy.tier(forAbsMs: abs(meanMs), slotIOIMs: slotIOIMs)
        self.stability = stability
        self.accuracy = accuracy
        // Stability-primary: accuracy drags the verdict at most one tier
        // below stability. A steady player with a constant offset is
        // fundamentally solid (constant bias is partly a latency artifact);
        // no amount of mean-centering redeems inconsistency.
        let oneBelowStability = TimingTier(rawValue: max(stability.rawValue - 1, 0))!
        self.overall = max(min(stability, accuracy), oneBelowStability)
    }

    /// Interval of one analysis-grid slot in ms — the IOI the player is
    /// actually producing, and the basis for tempo normalization.
    public static func slotIOIMs(bpm: Double, subdivision: Subdivision) -> Double {
        guard bpm > 0 else { return 0 }
        return 60_000 / (bpm * Double(subdivision.slotsPerBeat))
    }
}
