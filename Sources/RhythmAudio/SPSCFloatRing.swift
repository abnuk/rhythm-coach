import Synchronization

/// Lock-free single-producer/single-consumer ring buffer for audio samples.
/// Producer is the realtime IOProc; consumer is the analysis thread.
/// The producer never blocks: on overflow, samples are dropped and counted.
public final class SPSCFloatRing: @unchecked Sendable {
    private let capacity: Int
    private let mask: Int
    private let storage: UnsafeMutablePointer<Float>
    private let head = Atomic<Int>(0)     // total written (producer-owned)
    private let tail = Atomic<Int>(0)     // total read (consumer-owned)
    private let dropped = Atomic<Int>(0)

    /// - Parameter capacity: rounded up to the next power of two.
    public init(capacity: Int) {
        var cap = 16
        while cap < capacity { cap *= 2 }
        self.capacity = cap
        self.mask = cap - 1
        self.storage = .allocate(capacity: cap)
        self.storage.initialize(repeating: 0, count: cap)
    }

    deinit {
        storage.deallocate()
    }

    /// Realtime-safe producer write. Returns the number of samples accepted.
    @discardableResult
    public func write(_ samples: UnsafePointer<Float>, count: Int) -> Int {
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        let free = capacity - (h - t)
        let n = min(count, free)
        if n > 0 {
            let start = h & mask
            let firstRun = min(n, capacity - start)
            (storage + start).update(from: samples, count: firstRun)
            if n > firstRun {
                storage.update(from: samples + firstRun, count: n - firstRun)
            }
            head.store(h + n, ordering: .releasing)
        }
        if n < count {
            dropped.wrappingAdd(count - n, ordering: .relaxed)
        }
        return n
    }

    /// Consumer read into `buffer`. Returns the number of samples read.
    public func read(into buffer: UnsafeMutablePointer<Float>, maxCount: Int) -> Int {
        let t = tail.load(ordering: .relaxed)
        let h = head.load(ordering: .acquiring)
        let available = h - t
        let n = min(maxCount, available)
        if n > 0 {
            let start = t & mask
            let firstRun = min(n, capacity - start)
            buffer.update(from: storage + start, count: firstRun)
            if n > firstRun {
                (buffer + firstRun).update(from: storage, count: n - firstRun)
            }
            tail.store(t + n, ordering: .releasing)
        }
        return n
    }

    public var availableToRead: Int {
        head.load(ordering: .acquiring) - tail.load(ordering: .relaxed)
    }

    public var droppedSamples: Int {
        dropped.load(ordering: .relaxed)
    }
}
