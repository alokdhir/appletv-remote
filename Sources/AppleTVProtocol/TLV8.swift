import Foundation

/// HAP TLV8 encoder / decoder.
///
/// Format: each entry is tag (1 byte) + length (1 byte, 0–255) + data.
/// Values longer than 255 bytes are split into consecutive TLVs with the
/// same tag; the decoder automatically reassembles them.
public struct TLV8 {
    public enum Tag: UInt8 {
        case method        = 0x00
        case identifier    = 0x01
        case salt          = 0x02
        case publicKey     = 0x03
        case proof         = 0x04
        case encryptedData = 0x05
        case state         = 0x06
        case error         = 0x07
        case retryDelay    = 0x08
        case certificate   = 0x09
        case signature     = 0x0A
        case permissions   = 0x0B
        case fragmentData  = 0x0C
        case fragmentLast  = 0x0D
        case sessionID     = 0x0E
        case name          = 0x11   // Companion-specific: OPACK-encoded {"name": string}
        case separator     = 0xFF
    }

    private var entries: [(UInt8, Data)] = []

    public init() {}

    // MARK: - Builder

    public mutating func append(_ tag: Tag, _ value: Data) {
        entries.append((tag.rawValue, value))
    }

    public mutating func append(_ tag: Tag, byte value: UInt8) {
        entries.append((tag.rawValue, Data([value])))
    }

    // MARK: - Encode

    public func encode() -> Data {
        var out = Data()
        for (tag, value) in entries {
            var remaining = value
            // Fragment values > 255 bytes
            repeat {
                let chunk = remaining.prefix(255)
                remaining = remaining.dropFirst(chunk.count)
                out.append(tag)
                out.append(UInt8(chunk.count))
                out.append(contentsOf: chunk)
            } while !remaining.isEmpty
        }
        return out
    }

    // MARK: - Decode

    public enum DecodeError: Error, Equatable {
        /// Trailing tag byte with no length byte after it.
        case truncatedHeader
        /// Declared length runs off the end of the buffer.
        case undersizedValue(declared: Int, available: Int)
    }

    /// Parse TLV8 bytes. Throws `DecodeError` on malformed input rather than
    /// silently truncating — so an attacker-supplied short value surfaces as a
    /// wire-format error instead of a downstream ChaCha20-Poly1305 open() failure.
    public static func decode(_ data: Data) throws -> TLV8 {
        var tlv = TLV8()
        var i = data.startIndex

        while i < data.endIndex {
            guard data.index(after: i) < data.endIndex else {
                throw DecodeError.truncatedHeader
            }
            let tag  = data[i];  i = data.index(after: i)
            let len  = Int(data[i]); i = data.index(after: i)
            let available = data.distance(from: i, to: data.endIndex)
            guard available >= len else {
                throw DecodeError.undersizedValue(declared: len, available: available)
            }
            let end  = data.index(i, offsetBy: len)
            let value = Data(data[i..<end])
            i = end

            // Reassemble fragments with the same tag
            if let last = tlv.entries.last, last.0 == tag {
                tlv.entries[tlv.entries.count - 1].1.append(value)
            } else {
                tlv.entries.append((tag, value))
            }
        }
        return tlv
    }

    // MARK: - Lookup

    public subscript(tag: Tag) -> Data? {
        entries.first(where: { $0.0 == tag.rawValue })?.1
    }

    /// All entries as (tag byte, data) pairs — for debugging.
    public var allEntries: [(UInt8, Data)] { entries }
}
