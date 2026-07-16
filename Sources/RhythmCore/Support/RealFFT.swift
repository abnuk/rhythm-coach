import Accelerate
import Foundation

/// Real-input FFT wrapper around vDSP producing magnitude spectra.
/// Not thread-safe; one instance per processing thread.
final class RealFFT {
    let size: Int
    let halfSize: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var window: [Float]
    private var windowed: [Float]
    private var realPart: [Float]
    private var imagPart: [Float]

    init(size: Int) {
        precondition(size > 0 && size & (size - 1) == 0, "FFT size must be a power of two")
        self.size = size
        self.halfSize = size / 2
        self.log2n = vDSP_Length(log2(Double(size)).rounded())
        self.setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        self.window = [Float](repeating: 0, count: size)
        self.windowed = [Float](repeating: 0, count: size)
        self.realPart = [Float](repeating: 0, count: size / 2)
        self.imagPart = [Float](repeating: 0, count: size / 2)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    /// Computes the magnitude spectrum of `input` (exactly `size` samples)
    /// into `magnitudes` (`halfSize` bins; Nyquist bin dropped).
    func magnitudes(input: UnsafePointer<Float>, into magnitudes: UnsafeMutablePointer<Float>) {
        vDSP_vmul(input, 1, window, 1, &windowed, 1, vDSP_Length(size))
        realPart.withUnsafeMutableBufferPointer { realBuf in
            imagPart.withUnsafeMutableBufferPointer { imagBuf in
                var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    let complexPtr = raw.baseAddress!.assumingMemoryBound(to: DSPComplex.self)
                    vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(halfSize))
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                // Packed format: imagp[0] holds the Nyquist term; zero it so bin 0 is pure DC.
                split.imagp[0] = 0
                vDSP_zvabs(&split, 1, magnitudes, 1, vDSP_Length(halfSize))
            }
        }
        // zrip output is scaled by 2; normalize so magnitudes are window-energy scaled.
        var half: Float = 0.5
        vDSP_vsmul(magnitudes, 1, &half, magnitudes, 1, vDSP_Length(halfSize))
    }
}
