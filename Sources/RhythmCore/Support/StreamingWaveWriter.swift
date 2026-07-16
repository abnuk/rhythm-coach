import Foundation

/// Incremental mono Float32 WAV writer for session recording: streams data
/// to disk as it arrives and patches the RIFF sizes on finalize, so memory
/// use is constant and a crash loses at most the header patch.
public final class StreamingWaveWriter {
    public let url: URL
    public let sampleRate: Double
    private let handle: FileHandle
    private var dataBytes: UInt32 = 0
    private var finalized = false

    public init(url: URL, sampleRate: Double) throws {
        self.url = url
        self.sampleRate = sampleRate
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: url)

        var header = Data()
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        header.append(contentsOf: Array("RIFF".utf8))
        append(36)  // patched on finalize
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        append(16)
        append16(3)  // IEEE float
        append16(1)  // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 4))
        append16(4)
        append16(32)
        header.append(contentsOf: Array("data".utf8))
        append(0)  // patched on finalize
        try handle.write(contentsOf: header)
    }

    public func append(_ samples: UnsafeBufferPointer<Float>) throws {
        guard !finalized, let base = samples.baseAddress else { return }
        let data = Data(bytes: base, count: samples.count * 4)
        try handle.write(contentsOf: data)
        dataBytes += UInt32(data.count)
    }

    public func append(_ samples: [Float]) throws {
        try samples.withUnsafeBufferPointer { try append($0) }
    }

    /// Patches sizes and closes the file. Safe to call once.
    public func finalize() throws {
        guard !finalized else { return }
        finalized = true
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: withUnsafeBytes(of: (36 + dataBytes).littleEndian) { Data($0) })
        try handle.seek(toOffset: 40)
        try handle.write(contentsOf: withUnsafeBytes(of: dataBytes.littleEndian) { Data($0) })
        try handle.close()
    }

    deinit {
        try? finalize()
    }
}
