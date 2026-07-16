import Foundation
import RhythmAudio

@MainActor struct SPSCFloatRingTests {
    func wrapAround() {
        let ring = SPSCFloatRing(capacity: 1024)
        var next: Float = 0
        var expected: Float = 0
        var readBuf = [Float](repeating: 0, count: 300)

        for _ in 0..<200 {
            var chunk = [Float](repeating: 0, count: 173)
            for i in 0..<chunk.count { chunk[i] = next; next += 1 }
            chunk.withUnsafeBufferPointer { _ = ring.write($0.baseAddress!, count: $0.count) }

            while ring.availableToRead > 0 {
                let n = readBuf.withUnsafeMutableBufferPointer {
                    ring.read(into: $0.baseAddress!, maxCount: $0.count)
                }
                for i in 0..<n {
                    expect(readBuf[i] == expected)
                    expected += 1
                }
            }
        }
        expect(ring.droppedSamples == 0)
    }

    func overflow() {
        let ring = SPSCFloatRing(capacity: 256)
        let big = [Float](repeating: 1, count: 1000)
        let accepted = big.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: $0.count) }
        expect(accepted == 256)
        expect(ring.droppedSamples == 744)
    }

    func concurrent() async {
        let ring = SPSCFloatRing(capacity: 4096)
        let total = 500_000

        let producer = Task.detached {
            var next: Float = 0
            var chunk = [Float](repeating: 0, count: 512)
            var written = 0
            while written < total {
                let n = min(512, total - written)
                for i in 0..<n { chunk[i] = next + Float(i) }
                let accepted = chunk.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: n) }
                written += accepted
                next += Float(accepted)
                if accepted == 0 { await Task.yield() }
            }
        }

        var expected: Float = 0
        var readBuf = [Float](repeating: 0, count: 1024)
        var readTotal = 0
        while readTotal < total {
            let n = readBuf.withUnsafeMutableBufferPointer {
                ring.read(into: $0.baseAddress!, maxCount: $0.count)
            }
            if n == 0 { await Task.yield(); continue }
            for i in 0..<n {
                if readBuf[i] != expected {
                    recordIssue("mismatch at \(readTotal + i): \(readBuf[i]) != \(expected)")
                    await producer.value
                    return
                }
                expected += 1
            }
            readTotal += n
        }
        await producer.value
        expect(readTotal == total)
    }
}
