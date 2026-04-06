import Foundation

/// Constructs MRP wire messages (length-prefixed protobuf ProtocolMessage frames).
///
/// ProtocolMessage structure (proto2):
///   field 1  type  : int32   — message type enum value
///   field N  inner : bytes   — where N equals the type enum value (extension pattern)
///
/// Extension field numbers match the message type enum values, so:
///   DEVICE_INFO_MESSAGE    (1) → DeviceInfoMessage    at field 1
///   CRYPTO_PAIRING_MESSAGE (6) → CryptoPairingMessage at field 6
///   SEND_COMMAND_MESSAGE   (9) → SendCommandMessage   at field 9
///
/// CryptoPairingMessage fields:
///   field 1  pairingData : bytes  — TLV8-encoded HAP pairing payload
///   field 2  status      : int32  — optional error status
///
/// SendCommandMessage fields:
///   field 1  command : int32  — HIDUsage enum value
///   field 2  down    : bool   — true = key down, false = key up
enum MRPMessage {
    case remoteCommand(RemoteCommand)
    case deviceInfo
    case cryptoPairing(Data)   // data = TLV8-encoded HAP pairing payload

    // MARK: - Message type IDs

    private enum MessageType: Int32 {
        case deviceInfo      = 1
        case cryptoPairing   = 6
        case sendCommand     = 9
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

    // MARK: - Encode

    func encoded() -> Data? {
        switch self {
        case .remoteCommand(let command):
            return encodeRemoteCommand(command)
        case .deviceInfo:
            return encodeDeviceInfo()
        case .cryptoPairing(let tlv8):
            return encodeCryptoPairing(tlv8)
        }
    }

    // MARK: - Private builders

    private func encodeRemoteCommand(_ command: RemoteCommand) -> Data? {
        guard let usage = hidUsage(for: command) else { return nil }
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

        // ProtocolMessage: { type: 9 (SEND_COMMAND), field 9: inner }
        var outer = Data()
        outer.appendVarintField(fieldNumber: 1, value: Int64(MessageType.sendCommand.rawValue))
        outer.appendBytesField(fieldNumber: Int(MessageType.sendCommand.rawValue), value: inner)

        return frameLengthPrefixed(outer)
    }

    private func encodeDeviceInfo() -> Data {
        // DeviceInfoMessage: { uniqueIdentifier: <UUID>, name: "Mac Remote" }
        var inner = Data()
        inner.appendStringField(fieldNumber: 1, value: UUID().uuidString)
        inner.appendStringField(fieldNumber: 2, value: "Mac Remote")

        var outer = Data()
        outer.appendVarintField(fieldNumber: 1, value: Int64(MessageType.deviceInfo.rawValue))
        outer.appendBytesField(fieldNumber: Int(MessageType.deviceInfo.rawValue), value: inner)

        return frameLengthPrefixed(outer)
    }

    private func encodeCryptoPairing(_ tlv8: Data) -> Data {
        // CryptoPairingMessage: { pairingData: tlv8 }
        var inner = Data()
        inner.appendBytesField(fieldNumber: 1, value: tlv8)

        // ProtocolMessage: { type: 6 (CRYPTO_PAIRING), field 6: inner }
        var outer = Data()
        outer.appendVarintField(fieldNumber: 1, value: Int64(MessageType.cryptoPairing.rawValue))
        outer.appendBytesField(fieldNumber: Int(MessageType.cryptoPairing.rawValue), value: inner)

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

    private func frameLengthPrefixed(_ data: Data) -> Data {
        var frame = Data()
        frame.appendVarint(UInt64(data.count))
        frame.append(data)
        return frame
    }
}

// MARK: - Data protobuf helpers

extension Data {
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
