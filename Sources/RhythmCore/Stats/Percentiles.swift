import Foundation

public extension Array where Element == Double {
    /// Percentile by linear interpolation between closest ranks
    /// (NumPy `linear` / Excel `PERCENTILE.INC`). `p` is in `0...100`.
    /// Empty array → 0; a single element → that element. Order-agnostic.
    func percentile(_ p: Double) -> Double {
        guard !isEmpty else { return 0 }
        let s = sorted()
        guard s.count > 1 else { return s[0] }
        let rank = (p / 100) * Double(s.count - 1)   // 0-based fractional rank
        let lo = Int(rank.rounded(.down))
        let hi = Int(rank.rounded(.up))
        return s[lo] + (rank - Double(lo)) * (s[hi] - s[lo])
    }

    /// Middle value; interpolated for even counts. Empty → 0.
    var median: Double { percentile(50) }
}
