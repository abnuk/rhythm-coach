# RhythmCoach

A macOS rhythm-training tool for guitarists. Plays a configurable metronome
click, records your guitar (clean DI from an audio interface), detects every
note/strum onset and scores it against the click grid on one shared sample
clock — with statistics that separate **bias** (where you sit relative to the
beat) from **stability** (how consistent you are).

## Why it's accurate

- **CoreAudio HAL duplex engine** — click playback and guitar capture run in
  a single realtime callback on one device (or a private aggregate with drift
  compensation when input ≠ output), so both live on the same sample clock.
  The click is rendered sample-accurately inside the callback.
- **Real latency calibration** — driver-reported latency
  (device + safety offset + stream + buffer) is only the fallback. The
  built-in loopback test (cable from output to input, or a virtual device
  like BlackHole) measures the true round-trip constant by cross-correlating
  a click train; a manual driver-error offset (like Ableton's DEC) stacks on
  top. Verified: 0.00-sample measurement SD on loopback.
- **Guitar-tuned onset engine** — a custom implementation of SuperFlux
  (Böck & Widmer, DAFx-13) with adaptive whitening (Stowell & Plumbley):
  STFT → per-bin whitening → quarter-tone triangular filterbank → log
  compression → max-filtered rectified spectral flux → online peak picking →
  sub-hop refinement (parabolic novelty interpolation + envelope-slope
  anchoring in the raw waveform). Detects single notes *and* strummed chords
  (a strum is one event, not six), suppresses vibrato/bend false positives,
  and survives quiet palm-muted notes right after loud strums.
- Full-system selftest (own click through a physical/virtual loopback):
  mean +0.2 ms, **SD 0.000 ms** across buffer sizes and sample rates.

## Statistics (per Repp & Su's sensorimotor-synchronization literature)

- **Mean signed asynchrony** — your bias: behind (+) or ahead (−) of the beat
- **SD of asynchrony** — your stability; the research-validated skill metric
- min/max, % within tolerance window, deviation histogram (±100 ms)
- **Drift** — linear-regression slope of deviation over time (ms/min):
  detects gradual rushing/dragging that a plain average hides
- lag-1 autocorrelation of deviations (error-correction behaviour)
- ms ↔ % of beat interval; per-hit scatter timeline (early/late by color
  *and* position); session history with SD/mean trends over days

## Training features

- Grid subdivisions: 1/4, 1/8, 1/16, and triplets (1/8T, 1/16T)
- **Click density decoupled from tracking**: hear quarter-note clicks (or one
  per bar) while every 16th you play is still scored against the full grid
- **Target-offset mode**: practice sitting e.g. 15 ms *behind* the beat —
  scoring is relative to the shifted reference
- **Gap click**: N bars on / M bars silent (silent bars still scored)
- **Rest-friendly scoring**: optionally stop counting empty slots as
  "missed" when practicing patterns with rests
- Count-in, accent patterns, three synthesized click sounds
- Optional input monitoring through the app (guitar + click in headphones)
- DAW-style I/O routing: pick the input channel and the output stereo pair
  (per-device, remembered across launches)
- Session audio saved as two compact AAC files per take: the raw input and a
  click-overlaid mix for review (the click is placed where you heard it,
  using the session's latency compensation)

## Requirements & build

macOS 15+, Apple Silicon or Intel. Building needs only the Xcode **Command
Line Tools** (full Xcode works too):

```sh
./Scripts/make-app.sh          # builds dist/RhythmCoach.app (release)
swift run rc-tests             # hermetic test suite (52 tests)
swift run rc-cli devices       # headless harness: list devices
```

`rc-cli` subcommands: `devices`, `duplex` (engine smoke test), `calibrate`
(loopback latency), `gen-session` (synthesize a practice-take WAV with known
bias/jitter/latency), `analyze` (offline analysis of any WAV against a grid),
`selftest` (calibrate + score the app's own click through a loopback; asserts
mean ≤ 2 ms).

## Repository layout

```
Sources/RhythmCore/      DSP + grid + scoring + stats (no UI/HAL deps → portable to iOS)
Sources/RhythmAudio/     CoreAudio HAL: devices, duplex engine, RT context, calibrator
Sources/RhythmCoachApp/  SwiftUI app: practice, history, audio setup; SQLite persistence
Sources/rc-cli/          headless harness for the audio stack
Sources/rc-tests/        test suite (synthesized Karplus-Strong guitar signals)
Scripts/make-app.sh      SwiftPM → .app bundle (no Xcode required)
```

## First run

1. Open `dist/RhythmCoach.app`, grant microphone access.
2. **Audio Setup**: pick your interface for input *and* output, choose sample
   rate and buffer size.
3. **Calibrate**: connect interface output → instrument input with a cable,
   click *Calibrate now* (once per device/rate/buffer combination).
4. **Practice**: set BPM and grid, hit Start, play. Headphones recommended.
