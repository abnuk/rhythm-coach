import Foundation

/// Parameters for the SuperFlux onset detector (Böck & Widmer, DAFx-13)
/// with adaptive whitening (Stowell & Plumbley, 2007).
///
/// The novelty function is normalized per band, so `delta` is in
/// "mean flux per band" units and stays comparable across configs.
public struct SuperFluxConfig: Codable, Sendable, Equatable {
    /// STFT size in samples (power of two).
    public var fftSize: Int
    /// Target novelty frame rate in frames per second; hop = round(sampleRate / fps).
    public var framesPerSecond: Double
    /// Filterbank spacing in bands per octave (24 = quarter-tone).
    public var bandsPerOctave: Int
    /// Filterbank frequency range.
    public var minFrequency: Double
    public var maxFrequency: Double
    /// Log compression: log10(1 + lambda * x).
    public var logLambda: Float
    /// Adaptive whitening peak relaxation time in seconds.
    public var whitenerRelaxationSeconds: Double
    /// Adaptive whitening magnitude floor.
    public var whitenerFloor: Float
    /// Distance (in frames) to the reference frame for the flux difference.
    public var muFrames: Int
    /// Max-filter radius across bands applied to the reference frame (1 => width 3).
    public var maxFilterRadius: Int
    /// Peak-picking windows in milliseconds.
    public var preMaxMs: Double
    public var postMaxMs: Double
    public var preAvgMs: Double
    public var postAvgMs: Double
    /// Novelty must exceed local average by `delta` (per-band-normalized units).
    public var delta: Float
    /// Minimum inter-onset interval; merges a strum into a single event.
    public var minIOIMs: Double
    /// Absolute novelty floor below which frames are treated as silence.
    public var silenceThreshold: Float
    /// Attack-rise gate: on a period-smoothed waveform envelope, the max
    /// within `attackPostMs` after the refined onset anchor must be at
    /// least this factor above the *minimum* within `attackPreMs` before
    /// it (dip-then-rise, the signature of a new note — even a soft ghost
    /// under a louder ringing neighbour). A novelty peak on a smoothly
    /// decaying tail shows no rise and is dropped instead of being
    /// reported as a false early onset. The gate only accepts or drops an
    /// onset; it never moves the anchor. Values <= 1.0 disable it. Note:
    /// purely spectral onsets with no energy rise (legato, hammer-ons)
    /// are gated out as well.
    public var attackRiseRatio: Float
    /// Attack gate, second condition: the post-anchor envelope max must
    /// also reach this fraction of the pre-anchor envelope *max*. Guards
    /// against slow beating swells rising out of a deep amplitude null,
    /// which pass the dip-then-rise test but recover only a small part of
    /// the recent crest within `attackPostMs`. Values <= 0 disable it.
    public var attackCrestFraction: Float
    /// Attack gate look-back window in milliseconds.
    public var attackPreMs: Double
    /// Attack gate look-ahead window in milliseconds.
    public var attackPostMs: Double

    public init(
        fftSize: Int = 2048,
        framesPerSecond: Double = 200,
        bandsPerOctave: Int = 24,
        minFrequency: Double = 27.5,
        maxFrequency: Double = 16000,
        logLambda: Float = 20,
        whitenerRelaxationSeconds: Double = 1.0,
        whitenerFloor: Float = 1e-3,
        muFrames: Int = 2,
        maxFilterRadius: Int = 1,
        preMaxMs: Double = 30,
        postMaxMs: Double = 30,
        preAvgMs: Double = 100,
        postAvgMs: Double = 70,
        delta: Float = 0.05,
        minIOIMs: Double = 30,
        silenceThreshold: Float = 0.01,
        attackRiseRatio: Float = 1.5,
        attackCrestFraction: Float = 0.4,
        attackPreMs: Double = 25,
        attackPostMs: Double = 10
    ) {
        self.fftSize = fftSize
        self.framesPerSecond = framesPerSecond
        self.bandsPerOctave = bandsPerOctave
        self.minFrequency = minFrequency
        self.maxFrequency = maxFrequency
        self.logLambda = logLambda
        self.whitenerRelaxationSeconds = whitenerRelaxationSeconds
        self.whitenerFloor = whitenerFloor
        self.muFrames = muFrames
        self.maxFilterRadius = maxFilterRadius
        self.preMaxMs = preMaxMs
        self.postMaxMs = postMaxMs
        self.preAvgMs = preAvgMs
        self.postAvgMs = postAvgMs
        self.delta = delta
        self.minIOIMs = minIOIMs
        self.silenceThreshold = silenceThreshold
        self.attackRiseRatio = attackRiseRatio
        self.attackCrestFraction = attackCrestFraction
        self.attackPreMs = attackPreMs
        self.attackPostMs = attackPostMs
    }
}

/// A detected onset on the detector's absolute sample timeline.
public struct Onset: Sendable, Equatable {
    /// Position in samples since the first sample fed to the detector.
    public var sampleTime: Double
    /// Peak novelty value (per-band-normalized flux).
    public var strength: Float

    public init(sampleTime: Double, strength: Float) {
        self.sampleTime = sampleTime
        self.strength = strength
    }
}
