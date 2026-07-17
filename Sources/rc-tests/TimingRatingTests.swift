import Foundation
import RhythmCore

@MainActor struct TimingRatingTests {
    /// Slot IOI 100 ms (16ths @ 150 BPM): percent thresholds fall below the
    /// floors, so the absolute floors govern. Boundaries inclusive.
    func floorRegime() {
        let ioi = 100.0
        expect(TierThresholds.stability.tier(forAbsMs: 8.0, slotIOIMs: ioi) == .pro)
        expect(TierThresholds.stability.tier(forAbsMs: 8.01, slotIOIMs: ioi) == .good)
        expect(TierThresholds.stability.tier(forAbsMs: 12.0, slotIOIMs: ioi) == .good)
        expect(TierThresholds.stability.tier(forAbsMs: 12.01, slotIOIMs: ioi) == .fair)
        expect(TierThresholds.stability.tier(forAbsMs: 20.0, slotIOIMs: ioi) == .fair)
        expect(TierThresholds.stability.tier(forAbsMs: 20.01, slotIOIMs: ioi) == .poor)
        expect(TierThresholds.accuracy.tier(forAbsMs: 5.0, slotIOIMs: ioi) == .pro)
        expect(TierThresholds.accuracy.tier(forAbsMs: 5.01, slotIOIMs: ioi) == .good)
        expect(TierThresholds.accuracy.tier(forAbsMs: 10.0, slotIOIMs: ioi) == .good)
        expect(TierThresholds.accuracy.tier(forAbsMs: 15.0, slotIOIMs: ioi) == .fair)
        expect(TierThresholds.accuracy.tier(forAbsMs: 15.01, slotIOIMs: ioi) == .poor)
    }

    /// Slot IOI 500 ms (quarters @ 120 BPM): percent thresholds govern —
    /// stability 15/25/40 ms, accuracy 10/20/30 ms.
    func percentRegime() {
        let ioi = 500.0
        expect(TierThresholds.stability.tier(forAbsMs: 15.0, slotIOIMs: ioi) == .pro)
        expect(TierThresholds.stability.tier(forAbsMs: 15.01, slotIOIMs: ioi) == .good)
        expect(TierThresholds.stability.tier(forAbsMs: 25.0, slotIOIMs: ioi) == .good)
        expect(TierThresholds.stability.tier(forAbsMs: 40.0, slotIOIMs: ioi) == .fair)
        expect(TierThresholds.stability.tier(forAbsMs: 40.01, slotIOIMs: ioi) == .poor)
        expect(TierThresholds.accuracy.tier(forAbsMs: 10.0, slotIOIMs: ioi) == .pro)
        expect(TierThresholds.accuracy.tier(forAbsMs: 20.0, slotIOIMs: ioi) == .good)
        expect(TierThresholds.accuracy.tier(forAbsMs: 30.0, slotIOIMs: ioi) == .fair)
        expect(TierThresholds.accuracy.tier(forAbsMs: 30.01, slotIOIMs: ioi) == .poor)
    }

    /// The pro stability floor (8 ms) meets 3% exactly at IOI = 266.67 ms;
    /// max() must hand over from floor to percent across that point.
    func crossover() {
        let crossIOI = 8.0 / 0.03
        expect(TierThresholds.stability.tier(forAbsMs: 8.0, slotIOIMs: crossIOI - 1) == .pro)
        expect(TierThresholds.stability.tier(forAbsMs: 8.2, slotIOIMs: crossIOI - 1) == .good)
        // 3% of 276.67 ms = 8.3 ms > floor, so 8.2 is back inside pro.
        expect(TierThresholds.stability.tier(forAbsMs: 8.2, slotIOIMs: crossIOI + 10) == .pro)
    }

    func signAndNil() {
        let rating = TimingRating(sdMs: 5, meanMs: -9, slotIOIMs: 100, hitCount: 10)
        expect(rating?.accuracy == .good, "|−9| ms rates on magnitude")
        expect(TimingRating(sdMs: 5, meanMs: 0, slotIOIMs: 100, hitCount: 1) == nil)
        expect(TimingRating(sdMs: 5, meanMs: 0, slotIOIMs: 0, hitCount: 10) == nil)
        expect(TimingRating.slotIOIMs(bpm: 120, subdivision: .eighth) == 250)
        expect(TimingRating.slotIOIMs(bpm: 0, subdivision: .quarter) == 0)
    }

    /// Overall = max(min(stability, accuracy), one tier below stability).
    func overallRule() {
        func overall(sd: Double, mean: Double) -> TimingTier? {
            // IOI 100 → floors govern: stability 8/12/20, accuracy 5/10/15.
            TimingRating(sdMs: sd, meanMs: mean, slotIOIMs: 100, hitCount: 10)?.overall
        }
        expect(overall(sd: 7, mean: 0) == .pro)     // (pro, pro)
        expect(overall(sd: 7, mean: 40) == .good)   // (pro, poor) → one below stability
        expect(overall(sd: 10, mean: 4) == .good)   // (good, pro) → min
        expect(overall(sd: 10, mean: 40) == .fair)  // (good, poor) → one below stability
        expect(overall(sd: 15, mean: 40) == .poor)  // (fair, poor)
        expect(overall(sd: 25, mean: 0) == .poor)   // (poor, pro)
    }
}

@MainActor struct RollingStatsTests {
    func tooFew() {
        let times = (0..<15).map(Double.init)
        let devs = [Double](repeating: 1, count: 15)
        expect(RollingStats.windowedSD(timesSec: times, deviationsMs: devs).isEmpty)
    }

    func constantInput() {
        let n = 40
        let times = (0..<n).map { Double($0) * 0.5 }
        let devs = [Double](repeating: 7, count: n)
        let points = RollingStats.windowedSD(timesSec: times, deviationsMs: devs)
        expect(points.count == n - RollingStats.windowHits + 1)
        expect(points.allSatisfy { $0.sdMs == 0 && abs($0.meanMs - 7) < 1e-12 })
        expect(points.first?.timeSec == times[RollingStats.windowHits - 1])
        expect(points.last?.timeSec == times[n - 1])
    }

    /// Exactly one window of 8×0 + 8×10: mean 5, sd = √(16·25/15).
    func closedFormWindow() {
        let devs = [Double](repeating: 0, count: 8) + [Double](repeating: 10, count: 8)
        let times = (0..<16).map(Double.init)
        let points = RollingStats.windowedSD(timesSec: times, deviationsMs: devs)
        expect(points.count == 1)
        expect(abs(points[0].meanMs - 5) < 1e-12)
        expect(abs(points[0].sdMs - (400.0 / 15).squareRoot()) < 1e-12)
    }

    func tightThenLoose() {
        var devs: [Double] = []
        for i in 0..<24 { devs.append(i % 2 == 0 ? 1 : -1) }
        for i in 0..<24 { devs.append(i % 2 == 0 ? 20 : -20) }
        let times = (0..<devs.count).map(Double.init)
        let points = RollingStats.windowedSD(timesSec: times, deviationsMs: devs)
        expect(points.first!.sdMs < 2)
        expect(points.last!.sdMs > 15)
    }
}
