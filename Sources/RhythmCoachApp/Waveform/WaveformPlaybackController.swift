import AVFoundation
import Observation

/// Playback state for one loaded take. AVAudioPlayer plays to the system
/// default output — deliberately independent of the practice engine's HAL
/// devices. End of playback is detected by polling in `tick()` (no delegate:
/// avoids an NSObject proxy and nonisolated-callback hops).
@MainActor
@Observable
final class WaveformPlaybackController {
    private(set) var isPlaying = false
    /// The only property that changes at tick rate. Read it solely from
    /// small leaf views (playhead overlay, time readout); during playback
    /// the canvas re-renders anyway via follow-scrolling viewport writes,
    /// but pausing must leave it fully static.
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    var isAvailable: Bool { player != nil }

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var timer: Timer?

    func load(url: URL) {
        stop()
        player = try? AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
        duration = player?.duration ?? 0
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard let player else { return }
        if currentTime >= duration - 0.05 {
            player.currentTime = 0
            currentTime = 0
        }
        guard player.play() else { return }
        isPlaying = true
        startTicking()
    }

    func pause() {
        guard let player else { return }
        player.pause()
        currentTime = player.currentTime
        isPlaying = false
        stopTicking()
    }

    /// Works both paused and playing; clamps to the take.
    func seek(toSample sample: Double, sampleRate: Double) {
        guard let player, sampleRate > 0 else { return }
        let time = (sample / sampleRate).clamped(to: 0...duration)
        player.currentTime = time
        currentTime = time
    }

    func stop() {
        stopTicking()
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    private func startTicking() {
        stopTicking()
        // 60 Hz for smooth follow-scrolling; .common mode so the playhead
        // keeps moving during scroll tracking.
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTicking() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let player else { return }
        if isPlaying && !player.isPlaying {
            // Finished. The player resets its own currentTime to 0 here, so
            // pin the published time to the end explicitly.
            currentTime = duration
            isPlaying = false
            stopTicking()
            return
        }
        currentTime = player.currentTime
    }
}
