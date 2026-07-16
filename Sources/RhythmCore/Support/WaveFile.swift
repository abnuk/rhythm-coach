import Foundation

/// Minimal mono WAV reader/writer (PCM 16-bit and IEEE Float32).
/// Used by tests, fixtures and the offline analysis path; the app records
/// sessions through AVAudioFile but reads them back with this.
public enum WaveFile {
    public enum WaveError: Error {
        case malformed(String)
        case unsupported(String)
    }

    public static func write(samples: [Float], sampleRate: Double, to url: URL) throws {
        var data = Data()
        let byteCount = samples.count * 4
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + byteCount))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(16)
        append16(3) // IEEE float
        append16(1) // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 4))
        append16(4)
        append16(32)
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(byteCount))
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: url)
    }

    public static func read(from url: URL) throws -> (samples: [Float], sampleRate: Double) {
        let data = try Data(contentsOf: url)
        guard data.count > 44,
              String(data: data[0..<4], encoding: .ascii) == "RIFF",
              String(data: data[8..<12], encoding: .ascii) == "WAVE" else {
            throw WaveError.malformed("not a RIFF/WAVE file")
        }
        var offset = 12
        var format: UInt16 = 0
        var channels: UInt16 = 0
        var sampleRate: Double = 0
        var bitsPerSample: UInt16 = 0
        var samples: [Float] = []

        func readU16(_ at: Int) -> UInt16 { data.subdata(in: at..<at + 2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) } }
        func readU32(_ at: Int) -> UInt32 { data.subdata(in: at..<at + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }

        while offset + 8 <= data.count {
            let chunkID = String(data: data[offset..<offset + 4], encoding: .ascii) ?? ""
            let chunkSize = Int(readU32(offset + 4))
            let body = offset + 8
            switch chunkID {
            case "fmt ":
                format = readU16(body)
                channels = readU16(body + 2)
                sampleRate = Double(readU32(body + 4))
                bitsPerSample = readU16(body + 14)
            case "data":
                let end = min(body + chunkSize, data.count)
                let bytes = data.subdata(in: body..<end)
                switch (format, bitsPerSample) {
                case (3, 32):
                    samples = bytes.withUnsafeBytes { raw in
                        let ptr = raw.bindMemory(to: Float.self)
                        return Array(ptr)
                    }
                case (1, 16):
                    samples = bytes.withUnsafeBytes { raw in
                        let ptr = raw.bindMemory(to: Int16.self)
                        return ptr.map { Float(Int16(littleEndian: $0)) / 32768.0 }
                    }
                default:
                    throw WaveError.unsupported("format=\(format) bits=\(bitsPerSample)")
                }
            default:
                break
            }
            offset = body + chunkSize + (chunkSize & 1)
        }
        guard sampleRate > 0, !samples.isEmpty else { throw WaveError.malformed("missing fmt or data chunk") }
        if channels > 1 {
            let ch = Int(channels)
            var mono = [Float](repeating: 0, count: samples.count / ch)
            for i in 0..<mono.count {
                var acc: Float = 0
                for c in 0..<ch { acc += samples[i * ch + c] }
                mono[i] = acc / Float(ch)
            }
            samples = mono
        }
        return (samples, sampleRate)
    }
}
