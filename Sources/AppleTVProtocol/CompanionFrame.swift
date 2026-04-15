import Foundation

/// Companion protocol wire frame.
///
/// Header: 1-byte type + 3-byte big-endian payload length.
/// Payload: TLV8 for pairing/verify frames, OPACK for encrypted control frames.
public struct CompanionFrame {

    public enum FrameType: UInt8 {
        case psStart = 0x03   // Pair-Setup M1 (client → ATV, initiates pairing)
        case psNext  = 0x04   // Pair-Setup M2–M6 (both directions)
        case pvStart = 0x05   // Pair-Verify M1 (client → ATV, initiates verify)
        case pvNext  = 0x06   // Pair-Verify M2–M4 (both directions)
        case eOPACK  = 0x08   // Encrypted OPACK (commands and events after session)
    }

    public let type: FrameType
    public let payload: Data

    public init(type: FrameType, payload: Data) {
        self.type = type
        self.payload = payload
    }

    // MARK: - Encode

    public var encoded: Data {
        let len = payload.count
        var out = Data(capacity: 4 + len)
        out.append(type.rawValue)
        out.append(UInt8((len >> 16) & 0xFF))
        out.append(UInt8((len >>  8) & 0xFF))
        out.append(UInt8( len        & 0xFF))
        out.append(payload)
        return out
    }

    // MARK: - Decode

    /// Attempt to read one frame from `buffer`, consuming its bytes on success.
    public static func read(from buffer: inout Data) -> CompanionFrame? {
        guard buffer.count >= 4 else { return nil }

        let typeByte = buffer[buffer.startIndex]
        let b1 = buffer[buffer.index(buffer.startIndex, offsetBy: 1)]
        let b2 = buffer[buffer.index(buffer.startIndex, offsetBy: 2)]
        let b3 = buffer[buffer.index(buffer.startIndex, offsetBy: 3)]
        let payloadLen = (Int(b1) << 16) | (Int(b2) << 8) | Int(b3)

        guard buffer.count >= 4 + payloadLen else { return nil }

        let payloadStart = buffer.index(buffer.startIndex, offsetBy: 4)
        let payloadEnd   = buffer.index(payloadStart, offsetBy: payloadLen)
        let payload = Data(buffer[payloadStart..<payloadEnd])
        buffer.removeFirst(4 + payloadLen)

        guard let type = FrameType(rawValue: typeByte) else {
            print("Companion: unknown frame type 0x\(String(typeByte, radix: 16))")
            return nil
        }

        return CompanionFrame(type: type, payload: payload)
    }
}
