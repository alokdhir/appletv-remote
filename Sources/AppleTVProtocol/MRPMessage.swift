import Foundation

/// Constructs MRP wire messages (varint-length-prefixed protobuf ProtocolMessage frames).
///
/// ProtocolMessage structure (proto2):
///   field 1  type  : int32   — message type enum value
///   field N  inner : bytes   — extension field matching the type enum value
///
/// References:
///   pyatv/protocols/mrp/messages.py
///   pyatv/protocols/mrp/protobuf/ProtocolMessage.proto
public enum MRPMessage {

    // MARK: - Message type IDs

    private enum MessageType: Int32 {
        case deviceInfo         = 15  // DEVICE_INFO_MESSAGE
        case clientUpdates      = 16  // CLIENT_UPDATES_CONFIG_MESSAGE
        case sendHIDEvent       = 8   // SEND_HID_EVENT_MESSAGE (key up/down)
        case setConnectionState = 38  // SET_CONNECTION_STATE_MESSAGE
    }

    // MARK: - HID usages for SendCommandMessage

    private enum HIDUsage: Int32 {
        case home         = 3
        case up           = 4
        case down         = 5
        case left         = 6
        case right        = 7
        case select       = 8
        case menu         = 9
        case playPause    = 11
        case skipForward  = 12
        case skipBackward = 13
        case volumeUp     = 14
        case volumeDown   = 15
    }

    // MARK: - Public factory

    /// DEVICE_INFO_MESSAGE — identifies this client to the ATV.
    public static func deviceInfo(uniqueIdentifier: String) -> Data {
        var inner = Data()
        inner.appendStringField(fieldNumber: 1, value: uniqueIdentifier)
        inner.appendStringField(fieldNumber: 2, value: "Mac Remote")
        inner.appendStringField(fieldNumber: 3, value: "iPhone")                // localizedModelName
        inner.appendStringField(fieldNumber: 5, value: "com.apple.TVRemote")    // applicationBundleIdentifier
        inner.appendStringField(fieldNumber: 6, value: "344.28")                // applicationBundleVersion
        inner.appendVarintField(fieldNumber: 7, value: 1)                       // protocolVersion
        inner.appendVarintField(fieldNumber: 8, value: 108)                     // lastSupportedMessageType
        inner.appendBoolField(fieldNumber: 9, value: true)                      // supportsSystemPairing
        inner.appendBoolField(fieldNumber: 10, value: true)                     // allowsPairing
        inner.appendBoolField(fieldNumber: 13, value: true)                     // supportsACL
        inner.appendBoolField(fieldNumber: 14, value: true)                     // supportsSharedQueue
        inner.appendVarintField(fieldNumber: 17, value: 2)                      // sharedQueueVersion

        var outer = Data()
        outer.appendVarintField(fieldNumber: 1, value: Int64(MessageType.deviceInfo.rawValue))
        outer.appendBytesField(fieldNumber: Int(MessageType.deviceInfo.rawValue), value: inner)
        return frameLengthPrefixed(outer)
    }

    /// SET_CONNECTION_STATE_MESSAGE — tells the ATV we are "Connected" (state=1).
    public static func setConnectionState() -> Data {
        var inner = Data()
        inner.appendVarintField(fieldNumber: 1, value: 1)   // state = Connected

        var outer = Data()
        outer.appendVarintField(fieldNumber: 1, value: Int64(MessageType.setConnectionState.rawValue))
        outer.appendBytesField(fieldNumber: Int(MessageType.setConnectionState.rawValue), value: inner)
        return frameLengthPrefixed(outer)
    }

    /// CLIENT_UPDATES_CONFIG_MESSAGE — subscribe to now-playing + volume pushes.
    public static func clientUpdatesConfig() -> Data {
        var inner = Data()
        inner.appendBoolField(fieldNumber: 1, value: true)   // artworkUpdates
        inner.appendBoolField(fieldNumber: 2, value: true)   // nowPlayingUpdates
        inner.appendBoolField(fieldNumber: 3, value: true)   // volumeUpdates
        inner.appendBoolField(fieldNumber: 4, value: false)  // keyboardUpdates

        var outer = Data()
        outer.appendVarintField(fieldNumber: 1, value: Int64(MessageType.clientUpdates.rawValue))
        outer.appendBytesField(fieldNumber: Int(MessageType.clientUpdates.rawValue), value: inner)
        return frameLengthPrefixed(outer)
    }

    /// SEND_COMMAND_MESSAGE — encodes key-down + key-up for a HID usage.
    public static func remoteCommand(_ command: AppleTVRemoteCommand) -> Data? {
        guard let usage = hidUsage(for: command) else { return nil }
        var result = Data()
        result.append(keyEvent(usage: usage, down: true))
        result.append(keyEvent(usage: usage, down: false))
        return result
    }

    // MARK: - Private helpers

    private static func keyEvent(usage: HIDUsage, down: Bool) -> Data {
        var inner = Data()
        inner.appendVarintField(fieldNumber: 1, value: Int64(usage.rawValue))
        inner.appendBoolField(fieldNumber: 2, value: down)

        var outer = Data()
        outer.appendVarintField(fieldNumber: 1, value: Int64(MessageType.sendHIDEvent.rawValue))
        outer.appendBytesField(fieldNumber: Int(MessageType.sendHIDEvent.rawValue), value: inner)
        return frameLengthPrefixed(outer)
    }

    private static func hidUsage(for command: AppleTVRemoteCommand) -> HIDUsage? {
        switch command {
        case .up:           return .up
        case .down:         return .down
        case .left:         return .left
        case .right:        return .right
        case .select:       return .select
        case .menu:         return .menu
        case .home:         return .home
        case .playPause:    return .playPause
        case .skipForward:  return .skipForward
        case .skipBackward: return .skipBackward
        case .volumeUp:     return .volumeUp
        case .volumeDown:   return .volumeDown
        default:            return nil
        }
    }

    private static func frameLengthPrefixed(_ data: Data) -> Data {
        var frame = Data()
        frame.appendVarint(UInt64(data.count))
        frame.append(data)
        return frame
    }
}

// MARK: - Data protobuf encode helpers (public — also used by MRPDecoder)

public extension Data {
    mutating func appendTag(fieldNumber: Int, wireType: Int) {
        appendVarint(UInt64((fieldNumber << 3) | wireType))
    }

    mutating func appendVarintField(fieldNumber: Int, value: Int64) {
        appendTag(fieldNumber: fieldNumber, wireType: 0)
        appendVarint(UInt64(bitPattern: value))
    }

    mutating func appendBoolField(fieldNumber: Int, value: Bool) {
        appendVarintField(fieldNumber: fieldNumber, value: value ? 1 : 0)
    }

    mutating func appendBytesField(fieldNumber: Int, value: Data) {
        appendTag(fieldNumber: fieldNumber, wireType: 2)
        appendVarint(UInt64(value.count))
        append(value)
    }

    mutating func appendStringField(fieldNumber: Int, value: String) {
        appendBytesField(fieldNumber: fieldNumber, value: Data(value.utf8))
    }

    mutating func appendVarint(_ value: UInt64) {
        var v = value
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            append(byte)
        } while v != 0
    }
}

// MARK: - Data protobuf decode helpers (public — used by MRPDecoder)

public extension Data {
    /// Read a protobuf varint field (wire type 0) for a given field number.
    /// Scans the entire buffer — O(n) but fine for small MRP messages.
    func protobufVarintField(fieldNumber: Int) -> UInt64? {
        var offset = 0
        while offset < count {
            guard let tag = readVarintFrom(offset: &offset) else { return nil }
            let wt = Int(tag & 0x7)
            let fn = Int(tag >> 3)
            switch wt {
            case 0:
                guard let value = readVarintFrom(offset: &offset) else { return nil }
                if fn == fieldNumber { return value }
            case 2:
                guard let len = readVarintFrom(offset: &offset) else { return nil }
                offset += Int(len)
            case 1: offset += 8
            case 5: offset += 4
            default: return nil
            }
        }
        return nil
    }

    /// Read a protobuf length-delimited field (wire type 2) for a given field number.
    func protobufBytesField(fieldNumber: Int) -> Data? {
        var offset = 0
        while offset < count {
            guard let tag = readVarintFrom(offset: &offset) else { return nil }
            let wt = Int(tag & 0x7)
            let fn = Int(tag >> 3)
            switch wt {
            case 0:
                guard readVarintFrom(offset: &offset) != nil else { return nil }
            case 2:
                guard let len = readVarintFrom(offset: &offset) else { return nil }
                let start = offset
                let end   = offset + Int(len)
                guard end <= count else { return nil }
                offset = end
                if fn == fieldNumber {
                    return Data(self[index(startIndex, offsetBy: start)..<index(startIndex, offsetBy: end)])
                }
            case 1: offset += 8
            case 5: offset += 4
            default: return nil
            }
        }
        return nil
    }

    /// Read a varint from a raw integer offset (not Data.Index).
    func readVarintFrom(offset: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < count {
            let byte = self[index(startIndex, offsetBy: offset)]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil
    }

    func readStringField(at offset: inout Int) -> String? {
        guard let bytes = readBytesField(at: &offset) else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    func readBytesField(at offset: inout Int) -> Data? {
        guard let len = readVarintFrom(offset: &offset) else { return nil }
        let start = offset
        let end   = offset + Int(len)
        guard end <= count else { return nil }
        offset = end
        return Data(self[index(startIndex, offsetBy: start)..<index(startIndex, offsetBy: end)])
    }
}

// MARK: - Remote command enum (protocol-layer copy)

/// Subset of HID commands understood by MRP. Kept in the protocol target so
/// MRPMessage can stay app-independent. The app-layer `RemoteCommand` enum
/// (in `AppleTVDevice.swift`) maps 1:1 to this.
public enum AppleTVRemoteCommand {
    case up, down, left, right, select
    case menu, home
    case playPause
    case skipForward, skipBackward
    case volumeUp, volumeDown
    case wake
}
