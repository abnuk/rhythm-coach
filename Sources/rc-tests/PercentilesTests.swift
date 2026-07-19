import Foundation
import RhythmCore

@MainActor struct PercentilesTests {
    private func approx(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool {
        abs(a - b) < eps
    }

    /// Degenerate inputs: empty → 0; a single element → that element for any p
    /// (so a one-take bucket collapses its band to a point).
    func degenerate() {
        let empty: [Double] = []
        expect(empty.median == 0)
        expect(empty.percentile(25) == 0)

        let one = [42.0]
        expect(one.percentile(0) == 42)
        expect(one.median == 42)
        expect(one.percentile(100) == 42)
        expect(one.p25 == one.p75, "single-element band must collapse")
    }

    /// Even count interpolates the midpoint between the two central values.
    func evenMedian() {
        expect(approx([10, 20, 30, 40].median, 25))
        expect(approx([1, 3].median, 2))
    }

    /// Odd count lands on the exact middle value.
    func oddMedian() {
        expect([10, 20, 30].median == 20)
        expect([5, 5, 5].median == 5)
    }

    /// Linear-interpolation percentiles on a known set: for [10,20,30,40]
    /// (n=4, ranks 0…3) p25 = rank 0.75 = 17.5, p75 = rank 2.25 = 32.5.
    func quartiles() {
        let s = [10.0, 20, 30, 40]
        expect(approx(s.percentile(25), 17.5))
        expect(approx(s.percentile(50), 25))
        expect(approx(s.percentile(75), 32.5))
    }

    /// Order-agnostic: shuffled input yields the same quartiles.
    func orderAgnostic() {
        let ordered = [10.0, 20, 30, 40]
        let shuffled = [40.0, 10, 30, 20]
        expect(approx(ordered.percentile(25), shuffled.percentile(25)))
        expect(approx(ordered.percentile(75), shuffled.percentile(75)))
    }
}

private extension Array where Element == Double {
    var p25: Double { percentile(25) }
    var p75: Double { percentile(75) }
}
