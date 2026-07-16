import CoreAudio
import Foundation

public enum HALError: Error, CustomStringConvertible {
    case osStatus(OSStatus, String)
    case unsupported(String)

    public var description: String {
        switch self {
        case .osStatus(let status, let what):
            let fourCC = withUnsafeBytes(of: status.bigEndian) { raw in
                String(bytes: raw.map { (32...126).contains($0) ? $0 : 63 }, encoding: .ascii) ?? ""
            }
            return "\(what) failed: OSStatus \(status) ('\(fourCC)')"
        case .unsupported(let what):
            return what
        }
    }
}

/// Thin typed wrappers over the CoreAudio HAL C property API.
enum HAL {
    static func check(_ status: OSStatus, _ what: @autoclosure () -> String) throws {
        guard status == noErr else { throw HALError.osStatus(status, what()) }
    }

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func dataSize(_ objectID: AudioObjectID, _ addr: AudioObjectPropertyAddress) throws -> UInt32 {
        var addr = addr
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(objectID, &addr, 0, nil, &size), "GetPropertyDataSize \(addr.mSelector)")
        return size
    }

    static func get<T>(_ objectID: AudioObjectID, _ addr: AudioObjectPropertyAddress, default value: T) throws -> T {
        var addr = addr
        var size = UInt32(MemoryLayout<T>.size)
        var value = value
        try check(AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value), "GetPropertyData \(addr.mSelector)")
        return value
    }

    static func getArray<T>(_ objectID: AudioObjectID, _ addr: AudioObjectPropertyAddress, of type: T.Type) throws -> [T] {
        var addr = addr
        var size = try dataSize(objectID, addr)
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        var result = [T](unsafeUninitializedCapacity: count) { _, initialized in initialized = count }
        try result.withUnsafeMutableBytes { raw in
            try check(AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, raw.baseAddress!), "GetPropertyData array \(addr.mSelector)")
        }
        return result
    }

    static func getString(_ objectID: AudioObjectID, _ addr: AudioObjectPropertyAddress) throws -> String {
        var addr = addr
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        try withUnsafeMutablePointer(to: &value) { ptr in
            try check(AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, ptr), "GetPropertyData string \(addr.mSelector)")
        }
        guard let value else { return "" }
        return value.takeRetainedValue() as String
    }

    static func set<T>(_ objectID: AudioObjectID, _ addr: AudioObjectPropertyAddress, to value: T) throws {
        var addr = addr
        var value = value
        try check(
            AudioObjectSetPropertyData(objectID, &addr, 0, nil, UInt32(MemoryLayout<T>.size), &value),
            "SetPropertyData \(addr.mSelector)"
        )
    }

    /// Total channel count of a device in one direction.
    static func channelCount(_ deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        let addr = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        guard let size = try? dataSize(deviceID, addr), size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        var addrVar = addr
        var sizeVar = size
        guard AudioObjectGetPropertyData(deviceID, &addrVar, 0, nil, &sizeVar, raw) == noErr else { return 0 }
        let ablPtr = raw.assumingMemoryBound(to: AudioBufferList.self)
        let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
