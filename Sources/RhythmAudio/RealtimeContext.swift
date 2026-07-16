import CoreAudio
import Foundation
import RhythmCore
import Synchronization

/// State shared with the realtime IOProc.
///
/// REALTIME RULES for `handleIO` and everything it calls:
///  - no allocation, no locks, no throws, no ObjC messaging, no os_log
///  - cross-thread values only through `Atomic` or the SPSC ring
///  - the only kernel call is `DispatchSemaphore.signal()` (never blocks)
///
/// Everything is preallocated in `init`; the IOProc block captures this
/// object unretained (the engine keeps it alive while the device runs).
public final class RealtimeContext: @unchecked Sendable {
    public let ring: SPSCFloatRing
    let renderer: ClickRenderer
    let inputChannel: Int
    let maxFrames: Int

    /// Samples rendered so far == the shared session clock. RT thread writes.
    let sampleCounter = Atomic<Int64>(0)
    let clickGainBits = Atomic<UInt32>(Float(0.8).bitPattern)
    let monitorGainBits = Atomic<UInt32>(Float(0).bitPattern)
    let overloads = Atomic<Int>(0)
    /// Anchor pair (sampleCounter, hostTime) refreshed ~1x/s for diagnostics.
    let anchorSample = Atomic<Int64>(0)
    let anchorHostTime = Atomic<UInt64>(0)

    public let dataAvailable = DispatchSemaphore(value: 0)

    private let monoScratch: UnsafeMutablePointer<Float>
    private let clickScratch: UnsafeMutablePointer<Float>
    private var framesSinceAnchor = 0

    public init(grid: ClickGrid, sound: ClickSound, inputChannel: Int, maxFrames: Int = 4096, ringSeconds: Double = 8) {
        self.ring = SPSCFloatRing(capacity: Int(grid.sampleRate * ringSeconds))
        self.renderer = ClickRenderer(grid: grid, sound: sound)
        self.inputChannel = inputChannel
        self.maxFrames = maxFrames
        self.monoScratch = .allocate(capacity: maxFrames)
        self.monoScratch.initialize(repeating: 0, count: maxFrames)
        self.clickScratch = .allocate(capacity: maxFrames)
        self.clickScratch.initialize(repeating: 0, count: maxFrames)
    }

    deinit {
        monoScratch.deallocate()
        clickScratch.deallocate()
    }

    public var sampleTime: Int64 { sampleCounter.load(ordering: .relaxed) }
    public var overloadCount: Int { overloads.load(ordering: .relaxed) }

    public func setClickGain(_ gain: Float) {
        clickGainBits.store(gain.bitPattern, ordering: .relaxed)
    }

    public func setMonitorGain(_ gain: Float) {
        monitorGainBits.store(gain.bitPattern, ordering: .relaxed)
    }

    /// The realtime callback body.
    func handleIO(
        input: UnsafePointer<AudioBufferList>,
        inputTime: UnsafePointer<AudioTimeStamp>,
        output: UnsafeMutablePointer<AudioBufferList>,
        outputTime: UnsafePointer<AudioTimeStamp>,
        now: UnsafePointer<AudioTimeStamp>
    ) {
        let outputABL = UnsafeMutableAudioBufferListPointer(output)
        let inputABL = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))

        // Frame count from the output (fall back to input for input-only devices).
        var frames = 0
        for buf in outputABL where buf.mNumberChannels > 0 {
            frames = Int(buf.mDataByteSize) / (Int(buf.mNumberChannels) * MemoryLayout<Float>.size)
            break
        }
        if frames == 0 {
            for buf in inputABL where buf.mNumberChannels > 0 {
                frames = Int(buf.mDataByteSize) / (Int(buf.mNumberChannels) * MemoryLayout<Float>.size)
                break
            }
        }
        guard frames > 0, frames <= maxFrames else { return }

        let start = sampleCounter.load(ordering: .relaxed)
        let clickGain = Float(bitPattern: clickGainBits.load(ordering: .relaxed))
        let monitorGain = Float(bitPattern: monitorGainBits.load(ordering: .relaxed))

        // 1. Extract the configured input channel as mono.
        var haveInput = false
        var channelBase = 0
        for buf in inputABL {
            let channels = Int(buf.mNumberChannels)
            guard channels > 0, let data = buf.mData else { continue }
            if inputChannel >= channelBase && inputChannel < channelBase + channels {
                let ptr = data.assumingMemoryBound(to: Float.self)
                let localChannel = inputChannel - channelBase
                let available = Int(buf.mDataByteSize) / (channels * MemoryLayout<Float>.size)
                let n = min(frames, available)
                var i = 0
                while i < n {
                    monoScratch[i] = ptr[i * channels + localChannel]
                    i += 1
                }
                while i < frames {
                    monoScratch[i] = 0
                    i += 1
                }
                haveInput = true
                break
            }
            channelBase += channels
        }
        if !haveInput {
            for i in 0..<frames { monoScratch[i] = 0 }
        }

        // 2. Ship input to the analysis thread.
        ring.write(monoScratch, count: frames)

        // 3. Render the click for this buffer.
        for i in 0..<frames { clickScratch[i] = 0 }
        renderer.render(into: clickScratch, frames: frames, startSample: start, gain: clickGain)

        // 4. Write click + input monitoring into every output channel.
        for buf in outputABL {
            let channels = Int(buf.mNumberChannels)
            guard channels > 0, let data = buf.mData else { continue }
            let ptr = data.assumingMemoryBound(to: Float.self)
            let available = Int(buf.mDataByteSize) / (channels * MemoryLayout<Float>.size)
            let n = min(frames, available)
            for i in 0..<n {
                let sample = clickScratch[i] + monoScratch[i] * monitorGain
                for c in 0..<channels {
                    ptr[i * channels + c] = sample
                }
            }
        }

        // 5. Advance the shared clock, refresh the diagnostic anchor ~1x/s.
        sampleCounter.store(start + Int64(frames), ordering: .relaxed)
        framesSinceAnchor += frames
        if framesSinceAnchor >= 44100 {
            framesSinceAnchor = 0
            anchorSample.store(start, ordering: .relaxed)
            anchorHostTime.store(now.pointee.mHostTime, ordering: .relaxed)
        }

        // 6. Wake the analysis thread.
        dataAvailable.signal()
    }
}
