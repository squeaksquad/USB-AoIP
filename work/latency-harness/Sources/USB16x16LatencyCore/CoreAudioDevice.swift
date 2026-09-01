import CoreAudio
import Foundation

public enum CoreAudioInspectionError: Error, CustomStringConvertible {
    case osStatus(OSStatus, operation: String)
    case deviceNotFound(String)
    case invalidProperty(String)

    public var description: String {
        switch self {
        case let .osStatus(status, operation):
            return "\(operation) failed: \(Self.describe(status)) (\(status))"
        case let .deviceNotFound(name):
            return "CoreAudio device not found: \(name)"
        case let .invalidProperty(property):
            return "CoreAudio returned an invalid \(property) property"
        }
    }

    private static func describe(_ status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let bytes = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
        if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) {
            return "'\(String(bytes: bytes, encoding: .ascii) ?? "????")'"
        }
        return String(status)
    }
}

public struct NumericRange: Codable, Equatable, Sendable {
    public let minimum: Double
    public let maximum: Double
}

public struct StreamFormatSnapshot: Codable, Equatable, Sendable {
    public let streamID: UInt32
    public let sampleRate: Double
    public let formatID: String
    public let formatFlagsHex: String
    public let channels: UInt32
    public let bitsPerChannel: UInt32
    public let bytesPerFrame: UInt32
    public let framesPerPacket: UInt32
    public let interleaved: Bool
    public let latencyFrames: UInt32?
}

public struct DirectionSnapshot: Codable, Equatable, Sendable {
    public let channels: UInt32
    public let deviceLatencyFrames: UInt32?
    public let safetyOffsetFrames: UInt32?
    public let channelNames: [String]
    public let streams: [StreamFormatSnapshot]
}

public struct CoreAudioDeviceSnapshot: Codable, Equatable, Sendable {
    public let capturedAt: String
    public let deviceID: UInt32
    public let name: String
    public let uid: String?
    public let manufacturer: String?
    public let transportType: String?
    public let nominalSampleRate: Double
    public let actualSampleRate: Double?
    public let bufferFrameSize: UInt32
    public let bufferFrameSizeRanges: [NumericRange]
    public let isAlive: Bool?
    public let input: DirectionSnapshot
    public let output: DirectionSnapshot
}

public enum CoreAudioInspector {
    public static func allDevices() throws -> [CoreAudioDeviceSnapshot] {
        try deviceIDs().map(snapshot)
    }

    public static func snapshot(named requestedName: String) throws -> CoreAudioDeviceSnapshot {
        for deviceID in try deviceIDs() {
            if try stringProperty(deviceID, kAudioObjectPropertyName) == requestedName {
                return try snapshot(deviceID)
            }
        }
        throw CoreAudioInspectionError.deviceNotFound(requestedName)
    }

    public static func setBufferFrameSize(_ frames: UInt32, on deviceID: AudioDeviceID) throws {
        var value = frames
        var address = address(kAudioDevicePropertyBufferFrameSize)
        let status = withUnsafePointer(to: &value) {
            AudioObjectSetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<UInt32>.size),
                $0
            )
        }
        try check(status, "set buffer frame size")
    }

    private static func snapshot(_ deviceID: AudioDeviceID) throws -> CoreAudioDeviceSnapshot {
        let name = try stringProperty(deviceID, kAudioObjectPropertyName)
            ?? "AudioDevice \(deviceID)"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return CoreAudioDeviceSnapshot(
            capturedAt: formatter.string(from: Date()),
            deviceID: deviceID,
            name: name,
            uid: try stringProperty(deviceID, kAudioDevicePropertyDeviceUID),
            manufacturer: try stringProperty(deviceID, kAudioObjectPropertyManufacturer),
            transportType: try optionalUInt32(deviceID, kAudioDevicePropertyTransportType).map(fourCC),
            nominalSampleRate: try scalar(deviceID, kAudioDevicePropertyNominalSampleRate),
            actualSampleRate: try optionalScalar(deviceID, kAudioDevicePropertyActualSampleRate),
            bufferFrameSize: try uint32(deviceID, kAudioDevicePropertyBufferFrameSize),
            bufferFrameSizeRanges: try ranges(deviceID, kAudioDevicePropertyBufferFrameSizeRange),
            isAlive: try optionalUInt32(deviceID, kAudioDevicePropertyDeviceIsAlive).map { $0 != 0 },
            input: try direction(deviceID, scope: kAudioDevicePropertyScopeInput),
            output: try direction(deviceID, scope: kAudioDevicePropertyScopeOutput)
        )
    }

    private static func direction(
        _ deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) throws -> DirectionSnapshot {
        let channelCount = try channels(deviceID, scope: scope)
        let streamIDs = try streams(deviceID, scope: scope)
        let names = try (1...max(Int(channelCount), 0)).map { channel -> String in
            try stringProperty(
                deviceID,
                kAudioObjectPropertyElementName,
                scope: scope,
                element: AudioObjectPropertyElement(channel)
            ) ?? String(channel)
        }

        return DirectionSnapshot(
            channels: channelCount,
            deviceLatencyFrames: try optionalUInt32(
                deviceID,
                kAudioDevicePropertyLatency,
                scope: scope
            ),
            safetyOffsetFrames: try optionalUInt32(
                deviceID,
                kAudioDevicePropertySafetyOffset,
                scope: scope
            ),
            channelNames: names,
            streams: try streamIDs.map(streamSnapshot)
        )
    }

    private static func streamSnapshot(_ streamID: AudioStreamID) throws -> StreamFormatSnapshot {
        let format: AudioStreamBasicDescription = try value(
            streamID,
            kAudioStreamPropertyVirtualFormat
        )
        return StreamFormatSnapshot(
            streamID: streamID,
            sampleRate: format.mSampleRate,
            formatID: fourCC(format.mFormatID),
            formatFlagsHex: String(format: "0x%08x", format.mFormatFlags),
            channels: format.mChannelsPerFrame,
            bitsPerChannel: format.mBitsPerChannel,
            bytesPerFrame: format.mBytesPerFrame,
            framesPerPacket: format.mFramesPerPacket,
            interleaved: (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0,
            latencyFrames: try optionalUInt32(streamID, kAudioStreamPropertyLatency)
        )
    }

    private static func deviceIDs() throws -> [AudioDeviceID] {
        var propertyAddress = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject),
                &propertyAddress,
                0,
                nil,
                &size
            ),
            "get CoreAudio device-list size"
        )
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var result = [AudioDeviceID](repeating: 0, count: count)
        try result.withUnsafeMutableBytes { bytes in
            try check(
                AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &propertyAddress,
                    0,
                    nil,
                    &size,
                    bytes.baseAddress!
                ),
                "get CoreAudio device list"
            )
        }
        return result
    }

    private static func streams(
        _ deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) throws -> [AudioStreamID] {
        var propertyAddress = address(kAudioDevicePropertyStreams, scope: scope)
        guard AudioObjectHasProperty(deviceID, &propertyAddress) else { return [] }
        var size: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &size),
            "get stream-list size"
        )
        let count = Int(size) / MemoryLayout<AudioStreamID>.size
        var result = [AudioStreamID](repeating: 0, count: count)
        if count > 0 {
            try result.withUnsafeMutableBytes { bytes in
                try check(
                    AudioObjectGetPropertyData(
                        deviceID,
                        &propertyAddress,
                        0,
                        nil,
                        &size,
                        bytes.baseAddress!
                    ),
                    "get stream list"
                )
            }
        }
        return result
    }

    private static func channels(
        _ deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) throws -> UInt32 {
        var propertyAddress = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        guard AudioObjectHasProperty(deviceID, &propertyAddress) else { return 0 }
        var size: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &size),
            "get stream-configuration size"
        )
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        try check(
            AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &size, raw),
            "get stream configuration"
        )
        let audioBufferList = raw.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(audioBufferList).reduce(0) {
            $0 + $1.mNumberChannels
        }
    }

    private static func ranges(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector
    ) throws -> [NumericRange] {
        var propertyAddress = address(selector)
        guard AudioObjectHasProperty(objectID, &propertyAddress) else { return [] }
        var size: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(objectID, &propertyAddress, 0, nil, &size),
            "get numeric-range size"
        )
        let count = Int(size) / MemoryLayout<AudioValueRange>.size
        var values = [AudioValueRange](
            repeating: AudioValueRange(mMinimum: 0, mMaximum: 0),
            count: count
        )
        if count > 0 {
            try values.withUnsafeMutableBytes { bytes in
                try check(
                    AudioObjectGetPropertyData(
                        objectID,
                        &propertyAddress,
                        0,
                        nil,
                        &size,
                        bytes.baseAddress!
                    ),
                    "get numeric ranges"
                )
            }
        }
        return values.map { NumericRange(minimum: $0.mMinimum, maximum: $0.mMaximum) }
    }

    private static func stringProperty(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) throws -> String? {
        var propertyAddress = address(selector, scope: scope, element: element)
        guard AudioObjectHasProperty(objectID, &propertyAddress) else { return nil }
        var result: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(
            AudioObjectGetPropertyData(
                objectID,
                &propertyAddress,
                0,
                nil,
                &size,
                &result
            ),
            "get string property \(fourCC(selector))"
        )
        return result?.takeUnretainedValue() as String?
    }

    private static func scalar(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> Float64 {
        try value(objectID, selector, scope: scope)
    }

    private static func optionalScalar(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> Float64? {
        var propertyAddress = address(selector, scope: scope)
        guard AudioObjectHasProperty(objectID, &propertyAddress) else { return nil }
        return try scalar(objectID, selector, scope: scope)
    }

    private static func uint32(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> UInt32 {
        try value(objectID, selector, scope: scope)
    }

    private static func optionalUInt32(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> UInt32? {
        var propertyAddress = address(selector, scope: scope)
        guard AudioObjectHasProperty(objectID, &propertyAddress) else { return nil }
        return try uint32(objectID, selector, scope: scope)
    }

    private static func value<T>(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) throws -> T {
        var propertyAddress = address(selector, scope: scope, element: element)
        guard AudioObjectHasProperty(objectID, &propertyAddress) else {
            throw CoreAudioInspectionError.invalidProperty(fourCC(selector))
        }
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        var size = UInt32(MemoryLayout<T>.size)
        try check(
            AudioObjectGetPropertyData(
                objectID,
                &propertyAddress,
                0,
                nil,
                &size,
                pointer
            ),
            "get property \(fourCC(selector))"
        )
        guard size == UInt32(MemoryLayout<T>.size) else {
            throw CoreAudioInspectionError.invalidProperty(fourCC(selector))
        }
        return pointer.move()
    }

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
    }

    private static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw CoreAudioInspectionError.osStatus(status, operation: operation)
        }
    }

    private static func fourCC(_ value: UInt32) -> String {
        let bytes = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
        if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) {
            return String(bytes: bytes, encoding: .ascii) ?? String(value)
        }
        return String(format: "0x%08x", value)
    }
}
