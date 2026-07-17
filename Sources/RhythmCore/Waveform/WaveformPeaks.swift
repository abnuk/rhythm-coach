import Foundation

/// Immutable min/max peak pyramid over a mono sample buffer. Level k stores
/// one (min, max) bucket per `baseBucketSize << k` samples, so any zoom level
/// can be rendered by folding 1–2 buckets per pixel column instead of
/// scanning raw samples.
public struct WaveformPeaks: Sendable {
    public struct Bucket: Sendable, Equatable {
        public var min: Float
        public var max: Float

        public init(min: Float, max: Float) {
            self.min = min
            self.max = max
        }

        public static let zero = Bucket(min: 0, max: 0)

        public mutating func merge(_ other: Bucket) {
            min = Swift.min(min, other.min)
            max = Swift.max(max, other.max)
        }
    }

    public let baseBucketSize: Int
    public let sampleCount: Int
    /// levels[k] has one bucket per `baseBucketSize << k` samples.
    public let levels: [[Bucket]]

    public init(samples: [Float], baseBucketSize: Int = 16) {
        precondition(baseBucketSize > 0)
        self.baseBucketSize = baseBucketSize
        self.sampleCount = samples.count

        guard !samples.isEmpty else {
            self.levels = []
            return
        }

        var base = [Bucket]()
        base.reserveCapacity((samples.count + baseBucketSize - 1) / baseBucketSize)
        samples.withUnsafeBufferPointer { buffer in
            var i = 0
            while i < buffer.count {
                let end = Swift.min(i + baseBucketSize, buffer.count)
                var lo = buffer[i]
                var hi = buffer[i]
                for j in (i + 1)..<end {
                    let v = buffer[j]
                    if v < lo { lo = v }
                    if v > hi { hi = v }
                }
                base.append(Bucket(min: lo, max: hi))
                i = end
            }
        }

        var built = [base]
        while let last = built.last, last.count > 1 {
            var next = [Bucket]()
            next.reserveCapacity((last.count + 1) / 2)
            var i = 0
            while i < last.count {
                var bucket = last[i]
                if i + 1 < last.count { bucket.merge(last[i + 1]) }
                next.append(bucket)
                i += 2
            }
            built.append(next)
        }
        self.levels = built
    }

    /// The coarsest level whose bucket still spans no more than one pixel
    /// column, i.e. bucket size ≤ `samplesPerPoint`. Callers should render
    /// from raw samples when `samplesPerPoint < baseBucketSize`.
    public func levelIndex(forSamplesPerPoint samplesPerPoint: Double) -> Int {
        guard !levels.isEmpty else { return 0 }
        guard samplesPerPoint >= Double(baseBucketSize) else { return 0 }
        let level = Int(log2(samplesPerPoint / Double(baseBucketSize)))
        return Swift.min(level, levels.count - 1)
    }

    /// Conservative min/max over `sampleRange` using the given level: covers
    /// every bucket overlapping the range, so the result may extend up to one
    /// bucket beyond each edge. Returns .zero for empty/out-of-range input.
    public func minMax(level: Int, sampleRange: Range<Int>) -> Bucket {
        guard !levels.isEmpty, level < levels.count else { return .zero }
        let buckets = levels[level]
        let bucketSize = baseBucketSize << level
        let lo = Swift.max(0, sampleRange.lowerBound / bucketSize)
        let hi = Swift.min(buckets.count, (sampleRange.upperBound + bucketSize - 1) / bucketSize)
        guard lo < hi else { return .zero }
        var result = buckets[lo]
        for i in (lo + 1)..<hi { result.merge(buckets[i]) }
        return result
    }
}

/// A loaded take: raw samples plus the peak pyramid. Built off the main
/// thread once per file; both are kept so maximum zoom can show the exact
/// sample the analysis used.
public struct WaveformData: Sendable {
    public let samples: [Float]
    public let sampleRate: Double
    public let peaks: WaveformPeaks

    public init(samples: [Float], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.peaks = WaveformPeaks(samples: samples)
    }

    public static func load(url: URL) throws -> WaveformData {
        // Legacy takes are raw WAV; newer ones are AAC .m4a.
        let (samples, sampleRate) = url.pathExtension.lowercased() == "wav"
            ? try WaveFile.read(from: url)
            : try SessionAudioCodec.readMono(url: url)
        return WaveformData(samples: samples, sampleRate: sampleRate)
    }

    /// One (min, max) per pixel column starting at `startSample`. Columns
    /// wider than the pyramid base are answered from the pyramid; narrower
    /// ones straight from the raw samples. Out-of-range columns are .zero.
    public func columnMinMax(startSample: Double, samplesPerPoint: Double,
                             columns: Int) -> [WaveformPeaks.Bucket] {
        guard columns > 0, samplesPerPoint > 0, !samples.isEmpty else { return [] }
        var result = [WaveformPeaks.Bucket](repeating: .zero, count: columns)
        let usePyramid = samplesPerPoint >= Double(peaks.baseBucketSize)
        let level = peaks.levelIndex(forSamplesPerPoint: samplesPerPoint)

        for column in 0..<columns {
            let rangeStart = startSample + Double(column) * samplesPerPoint
            let rangeEnd = rangeStart + samplesPerPoint
            guard rangeEnd > 0, rangeStart < Double(samples.count) else { continue }
            let lo = Swift.max(0, Int(rangeStart.rounded(.down)))
            let hi = Swift.min(samples.count, Swift.max(lo + 1, Int(rangeEnd.rounded(.up))))
            guard lo < hi else { continue }
            if usePyramid {
                result[column] = peaks.minMax(level: level, sampleRange: lo..<hi)
            } else {
                var bucket = WaveformPeaks.Bucket(min: samples[lo], max: samples[lo])
                for i in (lo + 1)..<hi {
                    let v = samples[i]
                    if v < bucket.min { bucket.min = v }
                    if v > bucket.max { bucket.max = v }
                }
                result[column] = bucket
            }
        }
        return result
    }
}
