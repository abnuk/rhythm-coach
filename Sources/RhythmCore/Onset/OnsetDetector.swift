import Accelerate
import Foundation

/// Online SuperFlux onset detector with adaptive whitening and sub-hop
/// onset time refinement.
///
/// Pipeline per hop: STFT magnitudes -> adaptive whitening -> triangular
/// filterbank -> log compression -> max-filtered rectified flux (novelty)
/// -> online peak picking -> waveform-level refinement (envelope slope).
///
/// Feed arbitrary chunk sizes via `process`; onsets are emitted with a
/// bounded decision delay of max(postMax, postAvg) frames (~70-100 ms).
/// Not thread-safe: owned by a single analysis thread.
public final class OnsetDetector {
    public let config: SuperFluxConfig
    public let sampleRate: Double
    public let hopSize: Int

    private let fft: RealFFT
    private let filterbank: TriangularFilterbank
    private let bandCount: Int

    // Whitening state
    private var whitenerPeaks: [Float]
    private var whitenerGlobalPeak: Float = 1e-9
    private let whitenerDecay: Float

    // Spectral frames
    private var magnitudes: [Float]
    private var bandsRing: [[Float]]  // last (mu+1) band frames, indexed by frame % (mu+1)
    private var currentBands: [Float]
    private var maxFiltered: [Float]

    // Novelty history (absolute frame indexing)
    private var novelty: [Float]
    private let noveltyMask: Int
    private var frameCount: Int = 0  // next frame index to compute
    private var evalFrame: Int = 0   // next frame index to evaluate for peaks

    // Peak picking (in frames)
    private let preMaxF: Int
    private let postMaxF: Int
    private let preAvgF: Int
    private let postAvgF: Int
    private let minIOIF: Int
    private let postWindowF: Int
    private var lastPeakFrame: Int = .min / 2
    private var lastEmittedSample: Double = -1e12

    // Raw sample FIFO shared by framing and onset refinement. Kept long
    // enough behind the newest computed frame that a peak decided
    // `postWindowF` frames late can still be refined against raw samples.
    private var fifo: [Float]
    private var fifoStart: Int64 = 0   // absolute sample index of fifo[0]
    private var totalSamples: Int64 = 0
    private let keepBehindSamples: Int

    public init(config: SuperFluxConfig = SuperFluxConfig(), sampleRate: Double) {
        precondition(sampleRate > 0)
        self.config = config
        self.sampleRate = sampleRate
        self.hopSize = max(1, Int((sampleRate / config.framesPerSecond).rounded()))
        self.fft = RealFFT(size: config.fftSize)
        self.filterbank = TriangularFilterbank(
            binCount: config.fftSize / 2,
            sampleRate: sampleRate,
            fftSize: config.fftSize,
            bandsPerOctave: config.bandsPerOctave,
            minFrequency: config.minFrequency,
            maxFrequency: config.maxFrequency
        )
        self.bandCount = filterbank.bandCount
        precondition(bandCount > 8, "filterbank too small; check frequency range vs sample rate")

        self.whitenerPeaks = [Float](repeating: 1e-9, count: config.fftSize / 2)
        let framesPerRelax = config.whitenerRelaxationSeconds * config.framesPerSecond
        // Decay chosen so a peak falls to 10% after the relaxation time.
        self.whitenerDecay = pow(0.1, Float(1.0 / max(framesPerRelax, 1)))

        self.magnitudes = [Float](repeating: 0, count: config.fftSize / 2)
        self.bandsRing = Array(repeating: [Float](repeating: 0, count: bandCount), count: config.muFrames + 1)
        self.currentBands = [Float](repeating: 0, count: bandCount)
        self.maxFiltered = [Float](repeating: 0, count: bandCount)

        let fps = config.framesPerSecond
        func frames(_ ms: Double) -> Int { max(0, Int((ms / 1000 * fps).rounded())) }
        self.preMaxF = frames(config.preMaxMs)
        self.postMaxF = frames(config.postMaxMs)
        self.preAvgF = frames(config.preAvgMs)
        self.postAvgF = frames(config.postAvgMs)
        self.minIOIF = max(1, frames(config.minIOIMs))
        self.postWindowF = max(postMaxF, postAvgF)

        // Novelty ring must span look-back + look-ahead comfortably.
        let noveltySpan = max(preAvgF, preMaxF) + postWindowF + 8
        var novCap = 64
        while novCap < noveltySpan * 2 { novCap *= 2 }
        self.novelty = [Float](repeating: 0, count: novCap)
        self.noveltyMask = novCap - 1

        self.keepBehindSamples = config.fftSize * 2 + hopSize * (postWindowF + 4)
        self.fifo = []
        self.fifo.reserveCapacity(config.fftSize * 4 + keepBehindSamples)
    }

    public func reset() {
        whitenerPeaks.replaceSubrange(0..., with: repeatElement(1e-9, count: whitenerPeaks.count))
        whitenerGlobalPeak = 1e-9
        for i in 0..<bandsRing.count {
            bandsRing[i].replaceSubrange(0..., with: repeatElement(0, count: bandCount))
        }
        novelty.replaceSubrange(0..., with: repeatElement(0, count: novelty.count))
        frameCount = 0
        evalFrame = 0
        lastPeakFrame = .min / 2
        lastEmittedSample = -1e12
        fifo.removeAll(keepingCapacity: true)
        fifoStart = 0
        totalSamples = 0
    }

    /// Feeds samples; calls `emit` for each detected onset (possibly several).
    public func process(_ samples: UnsafeBufferPointer<Float>, emit: (Onset) -> Void) {
        guard samples.count > 0 else { return }
        totalSamples += Int64(samples.count)
        fifo.append(contentsOf: samples)

        // Compute all frames whose full window is available.
        while true {
            let frameStart = Int64(frameCount) * Int64(hopSize)
            let needed = frameStart + Int64(config.fftSize)
            guard needed <= totalSamples else { break }
            let offset = Int(frameStart - fifoStart)
            fifo.withUnsafeBufferPointer { buf in
                computeFrame(input: buf.baseAddress! + offset)
            }
            frameCount += 1

            // Evaluate any frame that now has full look-ahead.
            while evalFrame + postWindowF < frameCount {
                if let peak = evaluatePeak(at: evalFrame) {
                    refineAndEmit(peakFrame: evalFrame, fractional: peak.frac, strength: peak.value, emit: emit)
                }
                evalFrame += 1
            }
        }

        // Drop the FIFO head, retaining `keepBehindSamples` behind the next
        // frame so pending peak refinements can still read raw audio.
        let keepFrom = Int64(frameCount) * Int64(hopSize) - Int64(keepBehindSamples)
        let dropCount = Int(keepFrom - fifoStart)
        if dropCount > config.fftSize * 4 {
            fifo.removeFirst(dropCount)
            fifoStart = keepFrom
        }
    }

    /// Convenience for arrays.
    public func process(_ samples: [Float], emit: (Onset) -> Void) {
        samples.withUnsafeBufferPointer { process($0, emit: emit) }
    }

    /// Flushes the pipeline at end of stream (offline use).
    public func flush(emit: (Onset) -> Void) {
        let padFrames = postWindowF + config.muFrames + 4
        let pad = [Float](repeating: 0, count: padFrames * hopSize + config.fftSize)
        process(pad, emit: emit)
    }

    /// Offline convenience: detect all onsets in a buffer.
    public func detect(in samples: [Float]) -> [Onset] {
        reset()
        var result: [Onset] = []
        process(samples) { result.append($0) }
        flush { result.append($0) }
        return result
    }

    // MARK: - Internals

    private func computeFrame(input: UnsafePointer<Float>) {
        let halfSize = config.fftSize / 2
        magnitudes.withUnsafeMutableBufferPointer { magBuf in
            fft.magnitudes(input: input, into: magBuf.baseAddress!)
        }

        // Adaptive whitening: track per-bin peaks with decay and a floor
        // relative to the recent global peak, then normalize.
        var frameMax: Float = 0
        vDSP_maxv(magnitudes, 1, &frameMax, vDSP_Length(halfSize))
        whitenerGlobalPeak = max(frameMax, whitenerGlobalPeak * whitenerDecay, 1e-9)
        let floorValue = max(whitenerGlobalPeak * config.whitenerFloor, 1e-9)
        for k in 0..<halfSize {
            let p = max(magnitudes[k], floorValue, whitenerPeaks[k] * whitenerDecay)
            whitenerPeaks[k] = p
            magnitudes[k] /= p
        }

        // Filterbank + log compression.
        magnitudes.withUnsafeBufferPointer { magBuf in
            currentBands.withUnsafeMutableBufferPointer { bandBuf in
                filterbank.apply(spectrum: magBuf.baseAddress!, into: bandBuf.baseAddress!)
            }
        }
        let lambda = config.logLambda
        for b in 0..<bandCount {
            currentBands[b] = log10f(1 + lambda * currentBands[b])
        }

        // SuperFlux novelty vs the max-filtered frame mu hops back.
        let mu = config.muFrames
        let ringSize = mu + 1
        let refIndex = (frameCount + ringSize - mu) % ringSize
        let ref = bandsRing[refIndex]
        let radius = config.maxFilterRadius
        var flux: Float = 0
        if frameCount >= mu {
            for b in 0..<bandCount {
                var m = ref[b]
                let lo = max(0, b - radius), hi = min(bandCount - 1, b + radius)
                for j in lo...hi where ref[j] > m { m = ref[j] }
                maxFiltered[b] = m
                let d = currentBands[b] - m
                if d > 0 { flux += d }
            }
        }
        novelty[frameCount & noveltyMask] = flux / Float(bandCount)

        // Store current bands into the ring for future reference frames.
        bandsRing[frameCount % ringSize] = currentBands
    }

    private func evaluatePeak(at e: Int) -> (value: Float, frac: Double)? {
        let value = novelty[e & noveltyMask]
        guard value >= config.silenceThreshold else { return nil }
        guard e - lastPeakFrame >= minIOIF else { return nil }

        let maxLo = max(0, e - preMaxF)
        let maxHi = e + postMaxF
        var localMax: Float = -.greatestFiniteMagnitude
        for f in maxLo...maxHi {
            let v = novelty[f & noveltyMask]
            if v > localMax { localMax = v }
        }
        guard value >= localMax else { return nil }
        // Reject plateau re-triggers: require rise from the previous frame.
        if e > 0 && novelty[(e - 1) & noveltyMask] == value && value != localMax { return nil }

        let avgLo = max(0, e - preAvgF)
        let avgHi = e + postAvgF
        var sum: Float = 0
        for f in avgLo...avgHi { sum += novelty[f & noveltyMask] }
        let mean = sum / Float(avgHi - avgLo + 1)
        guard value >= mean + config.delta else { return nil }

        lastPeakFrame = e

        // Parabolic interpolation on the novelty peak for a fractional frame.
        var frac = 0.0
        if e > 0 {
            let y1 = Double(novelty[(e - 1) & noveltyMask])
            let y2 = Double(value)
            let y3 = Double(novelty[(e + 1) & noveltyMask])
            let denom = y1 - 2 * y2 + y3
            if abs(denom) > 1e-12 {
                frac = max(-0.5, min(0.5, 0.5 * (y1 - y3) / denom))
            }
        }
        return (value, frac)
    }

    /// Locates the attack in the raw waveform near the novelty peak using the
    /// maximum slope of a short-time RMS envelope, giving ~1-2 ms precision.
    private func refineAndEmit(peakFrame: Int, fractional: Double, strength: Float, emit: (Onset) -> Void) {
        let windowCenter = Double(peakFrame) * Double(hopSize) + fractional * Double(hopSize) + Double(config.fftSize) / 2
        let half = config.fftSize / 2
        var regionStart = Int64((windowCenter - Double(half) - Double(hopSize)).rounded())
        var regionEnd = Int64((windowCenter + Double(half) + Double(hopSize)).rounded())
        regionStart = max(regionStart, fifoStart, 0)
        regionEnd = min(regionEnd, totalSamples)
        let length = Int(regionEnd - regionStart)
        guard length > 512 else {
            emitChecked(Onset(sampleTime: windowCenter, strength: strength), emit: emit)
            return
        }

        // Short-time mean-absolute envelope (centered running mean over `envWin`).
        let envWin = 128
        let fifoOffset = Int(regionStart - fifoStart)
        var region = [Float](repeating: 0, count: length)
        for i in 0..<length {
            region[i] = abs(fifo[fifoOffset + i])
        }
        var envelope = [Float](repeating: 0, count: length)
        var running: Float = 0
        for i in 0..<length {
            running += region[i]
            if i >= envWin { running -= region[i - envWin] }
            let center = i - envWin / 2
            if center >= 0 { envelope[center] = running / Float(envWin) }
        }

        // Maximum slope of the envelope = attack anchor.
        let step = 64
        var bestSlope: Float = -.greatestFiniteMagnitude
        var bestIndex = length / 2
        var peakEnv: Float = 0
        for i in 0..<length where envelope[i] > peakEnv { peakEnv = envelope[i] }
        guard peakEnv > 1e-6 else {
            emitChecked(Onset(sampleTime: windowCenter, strength: strength), emit: emit)
            return
        }
        for i in step..<(length - envWin - step) {
            let slope = envelope[i + step] - envelope[i - step]
            if slope > bestSlope {
                bestSlope = slope
                bestIndex = i
            }
        }
        let refined = Double(regionStart) + Double(bestIndex)
        emitChecked(Onset(sampleTime: refined, strength: strength), emit: emit)
    }

    private func emitChecked(_ onset: Onset, emit: (Onset) -> Void) {
        let minGap = config.minIOIMs / 1000 * sampleRate
        guard onset.sampleTime - lastEmittedSample >= minGap else { return }
        lastEmittedSample = onset.sampleTime
        emit(onset)
    }
}
