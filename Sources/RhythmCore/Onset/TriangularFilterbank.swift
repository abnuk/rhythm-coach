import Foundation

/// Triangular filterbank on FFT bins with logarithmic (fraction-of-octave)
/// center spacing, madmom-style: candidate centers whose bin indices collide
/// are merged, and each filter spans neighbor-center to neighbor-center.
struct TriangularFilterbank {
    struct Filter {
        let startBin: Int
        let weights: [Float]
    }

    let filters: [Filter]
    var bandCount: Int { filters.count }

    init(binCount: Int, sampleRate: Double, fftSize: Int,
         bandsPerOctave: Int, minFrequency: Double, maxFrequency: Double) {
        let binHz = sampleRate / Double(fftSize)
        let nyquist = sampleRate / 2
        let fmax = min(maxFrequency, nyquist * 0.95)

        var centerBins: [Int] = []
        var f = minFrequency
        let step = pow(2.0, 1.0 / Double(bandsPerOctave))
        while f <= fmax {
            let bin = Int((f / binHz).rounded())
            if bin >= 1 && bin < binCount && bin != centerBins.last {
                centerBins.append(bin)
            }
            f *= step
        }

        var built: [Filter] = []
        guard centerBins.count >= 3 else {
            self.filters = []
            return
        }
        for i in 1..<(centerBins.count - 1) {
            let left = centerBins[i - 1]
            let center = centerBins[i]
            let right = centerBins[i + 1]
            var weights = [Float](repeating: 0, count: right - left + 1)
            for b in left...right {
                let w: Double
                if b < center {
                    w = Double(b - left) / Double(center - left)
                } else if b == center {
                    w = 1
                } else {
                    w = Double(right - b) / Double(right - center)
                }
                weights[b - left] = Float(w)
            }
            built.append(Filter(startBin: left, weights: weights))
        }
        self.filters = built
    }

    /// Applies the filterbank to a magnitude spectrum.
    func apply(spectrum: UnsafePointer<Float>, into bands: UnsafeMutablePointer<Float>) {
        for (i, filter) in filters.enumerated() {
            var acc: Float = 0
            let base = filter.startBin
            for (j, w) in filter.weights.enumerated() {
                acc += spectrum[base + j] * w
            }
            bands[i] = acc
        }
    }
}
