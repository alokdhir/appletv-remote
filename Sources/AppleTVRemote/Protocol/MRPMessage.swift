import Foundation

/// Constructs raw MRP wire messages.
///
/// MRP uses Protocol Buffers for all messages. Without importing the full protobuf
/// runtime as a dependency, we hand-encode the minimal fields needed for remote
/// control commands. Each message body is wrapped in a length-prefixed varint frame.
///
/// The outer wrapper message (ProtocolMessage) has these key fields:
///   field 1  (type) : int32   — message type enum value
///   field 3  (inner): bytes   — embedded sub-message (type-specific payload)
///
/// Command sub-message (SendCommandMessage) fields:
///   field 1  (command): int32 — HIDUsage enum value
///   field 2  (down)   : bool  — true = key down, false = key up
enum MRPMessage {
    case remoteCommand(RemoteCommand)
    case deviceInfo

    // MARK: - Message type IDs (from pyatv protobuf definitions)

    private enum MessageType: Int32 {
        case deviceInfo      = 1
        case sendCommand     = 9
        case clientUpdates   = 21
    }

    // MARK: - HID usages for the send-command message

    private enum HIDUsage: Int32 {
        case up           = 4
        case down         = 5
        case left         = 6
        case right        = 7
        case select       = 8   // center click / select
        case menu         = 9
        case playPause    = 11
        case skipForward  = 12  // next chapter / skip forward
        case skipBackward = 13  // previous chapter / skip back
        case home         = 3   // TV / home button
        case volumeUp     = 14
        case volumeDown   = 15
    }

    // MARK: - Encoding

    func encoded() -> Data? {
        switch self {
        case .remoteCommand(let command):
            return encodeRemoteCommand(command)
        case .deviceInfo:
            return encodeDeviceInfo()

        }
    }

    // MARK: - Private

    private func encodeRemoteCommand(_ command: RemoteCommand) -> Data? {
        guard let usage = hidUsage(for: command) else { return nil }

        // Encode two messages: key-down then key-up
        var result = Data()
        result.append(encodeKeyEvent(usage: usage, down: true))
        result.append(encodeKeyEvent(usage: usage, down: false))
        return result
    }

    private func encodeKeyEvent(usage: HIDUsage, down: Bool) -> Data {
        // SendCommandMessage: { command: usage, down: down }
        var inner = Data()
        inner.appendVarintField(fieldNumber: 1, value: Int64(usage.rawValue))
        inner.appendBoolField(fieldNumber: 2, value: down)

        // ProtocolMessage: { type: sendCommand, inner: inner }
        var outer = Data()
        outer.appendVarintField(fieldNumber: 1, value: Int64(MessageType.sendCommand.rawValue))
        outer.appendBytesField(fieldNumber: 3, value: inner)

        return frameLengthPrefixed(outer)
    }

    private func encodeDeviceInfo() -> Data {
        // Minimal DeviceInfoMessage: { uniqueIdentifier: <UUID string>, name: "Mac Remote" }
        let uuid = UUID().uuidString
        var inner = Data()
        inner.appendStringField(fieldNumber: 1, value: uuid)
        inner.appendStringField(fieldNumber: 2, value: "Mac Remote")

        var outer = Data()
        outer.appendVarintField(fieldNumber: 1, value: Int64(MessageType.deviceInfo.rawValue))
        outer.appendBytesField(fieldNumber: 3, value: inner)

        return frameLengthPrefixed(outer)
    }

    private func hidUsage(for command: RemoteCommand) -> HIDUsage? {
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
        }
    }

    /// Prepend a varint-encoded length to `data`.
    private func frameLengthPrefixed(_ data: Data) -> Data {
        var frame = Data()
        frame.appendVarint(UInt64(data.count))
        frame.append(data)
        return frame
    }
}

// MARK: - Data helpers for protobuf hand-encoding

private extension Data {
    // Wire type 0 = varint, 2 = length-delimited
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
        let bytes = Data(value.utf8)
        appendBytesField(fieldNumber: fieldNumber, value: bytes)
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
