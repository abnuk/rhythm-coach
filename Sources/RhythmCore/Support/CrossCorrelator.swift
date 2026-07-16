import Accelerate
import Foundation

/// Cross-correlation delay finder used by the loopback latency calibration:
/// locates a known template (the emitted click) inside a recorded signal.
public enum CrossCorrelator {
    /// Returns the lag (in samples, with sub-sample parabolic refinement) at
    /// which `template` best matches `signal`, searching lags
    /// `0 ..< signal.count - template.count`, or nil for degenerate input.
    public static func bestLag(signal: [Float], template: [Float]) -> Double? {
        let lagCount = signal.count - template.count
        guard lagCount > 2, !template.isEmpty else { return nil }

        var correlation = [Float](repeating: 0, count: lagCount)
        signal.withUnsafeBufferPointer { sig in
            template.withUnsafeBufferPointer { tpl in
                vDSP_conv(
                    sig.baseAddress!, 1,
                    tpl.baseAddress!, 1,
                    &correlation, 1,
                    vDSP_Length(lagCount),
                    vDSP_Length(template.count)
                )
            }
        }

        var maxValue: Float = 0
        var maxIndex: vDSP_Length = 0
        vDSP_maxvi(correlation, 1, &maxValue, &maxIndex, vDSP_Length(lagCount))
        guard maxValue > 0 else { return nil }

        let i = Int(maxIndex)
        var refined = Double(i)
        if i > 0 && i < lagCount - 1 {
            let y1 = Double(correlation[i - 1])
            let y2 = Double(correlation[i])
            let y3 = Double(correlation[i + 1])
            let denom = y1 - 2 * y2 + y3
            if abs(denom) > 1e-12 {
                refined += max(-0.5, min(0.5, 0.5 * (y1 - y3) / denom))
            }
        }
        return refined
    }
}
