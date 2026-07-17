import Foundation
import RhythmAudio
import RhythmCore
import Synchronization

/// Dedicated analysis thread: drains the realtime input ring, runs onset
/// detection, scores against the grid, accumulates statistics, and streams
/// the raw take to a WAV file. The UI polls `latestSnapshot` and drains
/// `takeEvents()` at display rate; nothing here touches the RT thread
/// except through the lock-free ring and the wake-up semaphore.
final class AnalysisPipeline: @unchecked Sendable {
    private let context: RealtimeContext
    private let detector: OnsetDetector
    private let scorer: TimingScorer
    private let stats: StatsAccumulator
    private let writer: StreamingWaveWriter?

    private let snapshotCell = Mutex<LiveStatsSnapshot>(LiveStatsSnapshot())
    private let eventsCell = Mutex<[ScoredEvent]>([])
    private let running = Atomic<Bool>(true)
    private var thread: Thread?

    init(context: RealtimeContext, grid: ClickGrid, latencyCompensationSamples: Double,
         toleranceMs: Double, recordingURL: URL?) {
        self.context = context
        self.detector = OnsetDetector(sampleRate: grid.sampleRate)
        self.scorer = TimingScorer(grid: grid, latencyCompensationSamples: latencyCompensationSamples)
        self.stats = StatsAccumulator(toleranceMs: toleranceMs, sampleRate: grid.sampleRate,
                                      slotIOIMs: grid.samplesPerSlot / grid.sampleRate * 1000)
        self.writer = recordingURL.flatMap { try? StreamingWaveWriter(url: $0, sampleRate: grid.sampleRate) }
    }

    var latestSnapshot: LiveStatsSnapshot {
        snapshotCell.withLock { $0 }
    }

    /// Returns and clears events accumulated since the last call.
    func takeEvents() -> [ScoredEvent] {
        eventsCell.withLock { events in
            let taken = events
            events.removeAll(keepingCapacity: true)
            return taken
        }
    }

    func start() {
        let thread = Thread { [self] in loop() }
        thread.name = "rhythmcoach.analysis"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    /// Stops the thread, finalizes the recording, returns final results.
    func stop() -> (snapshot: LiveStatsSnapshot, hits: [Hit], recordingURL: URL?) {
        running.store(false, ordering: .releasing)
        context.dataAvailable.signal()
        while thread?.isFinished == false {
            usleep(5_000)
        }
        try? writer?.finalize()
        return (stats.snapshot(), scorer.hits, writer?.url)
    }

    private func loop() {
        var chunk = [Float](repeating: 0, count: 32768)
        var consumedSamples: Int64 = 0

        while running.load(ordering: .acquiring) {
            _ = context.dataAvailable.wait(timeout: .now() + 0.1)

            while true {
                let n = chunk.withUnsafeMutableBufferPointer {
                    context.ring.read(into: $0.baseAddress!, maxCount: $0.count)
                }
                guard n > 0 else { break }
                consumedSamples += Int64(n)

                var newEvents: [ScoredEvent] = []
                chunk.withUnsafeBufferPointer { buf in
                    let slice = UnsafeBufferPointer(rebasing: buf[0..<n])
                    try? writer?.append(slice)
                    detector.process(slice) { onset in
                        newEvents.append(contentsOf: scorer.onOnset(onset))
                    }
                }
                // The detector decides ~100 ms late; advance missed-slot
                // bookkeeping with the same delay so hits land first.
                let decisionDelay = 0.25 * detector.sampleRate
                newEvents.append(contentsOf: scorer.advance(to: Double(consumedSamples) - decisionDelay))

                if !newEvents.isEmpty {
                    for event in newEvents { stats.add(event) }
                    eventsCell.withLock { $0.append(contentsOf: newEvents) }
                }
                snapshotCell.withLock { $0 = stats.snapshot() }
            }
        }
    }
}
