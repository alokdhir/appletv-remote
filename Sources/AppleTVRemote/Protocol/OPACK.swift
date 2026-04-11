import Foundation

/// Minimal OPACK encoder/decoder for the Companion protocol pairing frames.
///
/// Full OPACK spec (Apple internal binary serialization). We only implement
/// the subset needed: dicts with string keys and bytes/string/int values.
///
/// Wire types used here:
///   0x01         true
///   0x02         false
///   0x04         null
///   0x08–0x2F    small integers (value = byte - 0x08)
///   0x30         uint8  (1 byte follows)
///   0x31         uint16 (2 bytes, big-endian)
///   0x32         uint32 (4 bytes)
///   0x33         uint64 (8 bytes)
///   0x40–0x5F    string, length = byte - 0x40  (0–31 UTF-8 bytes)
///   0x60         string, 1-byte length follows
///   0x70–0x8F    bytes,  length = byte - 0x70  (0–31 bytes)
///   0x90         bytes,  1-byte length follows
///   0x91         bytes,  2-byte big-endian length follows
///   0x92         bytes,  4-byte big-endian length follows
///   0xD0–0xDF    array,  count = byte - 0xD0   (0–15 items)
///   0xE0–0xEF    dict,   count = byte - 0xE0   (0–15 key-value pairs)
enum OPACK {

    // MARK: - Pairing helpers

    // MARK: - HID command encoding

    /// Encode a HID button event for sending over the encrypted E_OPACK channel.
    ///
    /// Produces: `{ "_i": "_hidC", "_t": 2, "_x": txn, "_c": { "_hidC": keycode, "_hBtS": state } }`
    /// where state 1 = key-down, 2 = key-up.
    static func encodeHIDEvent(keycode: UInt8, state: UInt8, txn: UInt32) -> Data {
        var out = Data()
        out.append(0xE4)                        // dict, 4 entries
        encodeString("_i", into: &out)
        encodeString("_hidC", into: &out)
        encodeString("_t", into: &out)
        out.append(0x08 + 2)                    // small int: 2 (request)
        encodeString("_x", into: &out)
        encodeUInt32(txn, into: &out)
        encodeString("_c", into: &out)
        out.append(0xE2)                        // nested dict, 2 entries
        encodeString("_hidC", into: &out)
        out.append(0x08 + keycode)              // small int: keycode
        encodeString("_hBtS", into: &out)
        out.append(0x08 + state)                // small int: state
        return out
    }

    private static func encodeUInt32(_ value: UInt32, into out: inout Data) {
        out.append(0x32)
        out.append(UInt8((value >> 24) & 0xFF))
        out.append(UInt8((value >> 16) & 0xFF))
        out.append(UInt8((value >> 8)  & 0xFF))
        out.append(UInt8( value        & 0xFF))
    }

    // MARK: - General OPACK encoder

    /// Encode any Swift value into OPACK bytes.
    /// Supports: String, Int, UInt32, Bool, Data, [String: Any], [Any].
    static func pack(_ value: Any) -> Data {
        var out = Data()
        packValue(value, into: &out)
        return out
    }

    private static func packValue(_ value: Any, into out: inout Data) {
        switch value {
        case let s as String:
            encodeString(s, into: &out)
        case let i as Int:
            if i >= 0 && i <= 0x27 {
                out.append(UInt8(0x08 + i))
            } else {
                let u = UInt32(bitPattern: Int32(clamping: i))
                out.append(0x32)
                out.append(UInt8((u >> 24) & 0xFF))
                out.append(UInt8((u >> 16) & 0xFF))
                out.append(UInt8((u >> 8)  & 0xFF))
                out.append(UInt8( u        & 0xFF))
            }
        case let u as UInt32:
            encodeUInt32(u, into: &out)
        case let d as Data:
            encodeBytes(d, into: &out)
        case let b as Bool:
            out.append(b ? 0x01 : 0x02)
        case let dict as [String: Any]:
            let count = min(dict.count, 15)
            out.append(UInt8(0xE0 + count))
            for (k, v) in dict.prefix(count) {
                encodeString(k, into: &out)
                packValue(v, into: &out)
            }
        case let arr as [Any]:
            let count = min(arr.count, 15)
            out.append(UInt8(0xD0 + count))
            for item in arr.prefix(count) { packValue(item, into: &out) }
        default:
            out.append(0x04)  // null
        }
    }

    // MARK: - Session message helpers

    /// Encode a `_pong` response to an ATV `_ping` event.
    static func encodePong(txn: UInt32) -> Data {
        pack(["_i": "_pong", "_t": 2, "_x": txn] as [String: Any])
    }

    /// Encode `_systemInfo` request — tells the ATV who we are.
    static func encodeSystemInfo(clientID: String, txn: UInt32) -> Data {
        pack([
            "_i": "_systemInfo",
            "_t": 2,
            "_x": txn,
            "_c": [
                "_bf":   0,
                "_cf":   512,
                "_clFl": 128,
                "_i":    clientID,
                "_idsID": Data(clientID.utf8),
                "_pubID": clientID,
                "_sf":   256,
                "_sv":   "170.18",
                "model": "MacBookPro",
                "name":  "Mac Remote",
            ] as [String: Any],
        ] as [String: Any])
    }

    /// Encode `_sessionStart` request.
    static func encodeSessionStart(txn: UInt32, localSID: UInt32) -> Data {
        pack([
            "_i": "_sessionStart",
            "_t": 2,
            "_x": txn,
            "_c": [
                "_srvT": "com.apple.tvremoteservices",
                "_sid":  localSID,
            ] as [String: Any],
        ] as [String: Any])
    }

    /// Decode a top-level OPACK dict into [String: Any].
    /// Supports string, int, bytes, and nested dict values — enough for E_OPACK session messages.
    static func decodeDict(_ data: Data) -> [String: Any]? {
        var cursor = data.startIndex
        guard let count = readDictHeader(data, cursor: &cursor) else { return nil }
        var result = [String: Any]()
        for _ in 0..<count {
            guard let key = readString(data, cursor: &cursor) else { break }
            if let s = peekString(data, cursor: &cursor) {
                result[key] = s
            } else if let i = peekInt(data, cursor: &cursor) {
                result[key] = i
            } else if let b = peekBytes(data, cursor: &cursor) {
                result[key] = b
            } else if let d = peekNestedDict(data, cursor: &cursor) {
                result[key] = d
            } else {
                skipValue(data, cursor: &cursor)
            }
        }
        return result
    }

    private static func peekString(_ data: Data, cursor: inout Data.Index) -> String? {
        let saved = cursor
        if let s = readString(data, cursor: &cursor) { return s }
        cursor = saved; return nil
    }

    private static func peekInt(_ data: Data, cursor: inout Data.Index) -> Int? {
        guard cursor < data.endIndex else { return nil }
        let tag = data[cursor]
        switch tag {
        case 0x08...0x2F:
            data.formIndex(after: &cursor)
            return Int(tag) - 0x08
        case 0x30:
            guard data.distance(from: cursor, to: data.endIndex) >= 2 else { return nil }
            let v = Int(data[data.index(after: cursor)])
            data.formIndex(&cursor, offsetBy: 2)
            return v
        case 0x31:
            guard data.distance(from: cursor, to: data.endIndex) >= 3 else { return nil }
            let v = Int(data[data.index(cursor, offsetBy: 1)]) << 8 |
                    Int(data[data.index(cursor, offsetBy: 2)])
            data.formIndex(&cursor, offsetBy: 3)
            return v
        case 0x32:
            guard data.distance(from: cursor, to: data.endIndex) >= 5 else { return nil }
            let v = Int(data[data.index(cursor, offsetBy: 1)]) << 24 |
                    Int(data[data.index(cursor, offsetBy: 2)]) << 16 |
                    Int(data[data.index(cursor, offsetBy: 3)]) << 8  |
                    Int(data[data.index(cursor, offsetBy: 4)])
            data.formIndex(&cursor, offsetBy: 5)
            return v
        default: return nil
        }
    }

    private static func peekBytes(_ data: Data, cursor: inout Data.Index) -> Data? {
        let saved = cursor
        if let b = readBytes(data, cursor: &cursor) { return b }
        cursor = saved; return nil
    }

    private static func peekNestedDict(_ data: Data, cursor: inout Data.Index) -> [String: Any]? {
        let saved = cursor
        guard cursor < data.endIndex else { return nil }
        let tag = data[cursor]
        guard tag >= 0xE0, tag <= 0xEF else { return nil }
        if let d = decodeDict(data[cursor...]) { // decode sub-slice
            // advance cursor past the nested dict by re-parsing
            _ = readDictHeader(data, cursor: &cursor)
            let count = Int(tag - 0xE0)
            for _ in 0..<(count * 2) { skipValue(data, cursor: &cursor) }
            return d
        }
        cursor = saved; return nil
    }

    // MARK: - Pairing helpers

    /// Encode `{"name": displayName}` for the Companion-specific TLV8 tag=0x11 in pair-setup M5.
    /// This registers the controller in the Companion controller store on the ATV, which is the
    /// store checked during pair-verify. Without it, the ATV stores us in HAP-only and rejects
    /// pair-verify M3 with error=2 (Authentication).
    static func encodeDeviceName(_ displayName: String) -> Data {
        var out = Data()
        out.append(0xE1)   // dict, 1 entry
        encodeString("name", into: &out)
        encodeString(displayName, into: &out)
        return out
    }

    /// Wrap raw TLV8 bytes in `{"_pd": data}` for pvNext frames.
    static func wrapPairingData(_ tlvData: Data) -> Data {
        var out = Data()
        out.append(0xE1)                    // dict, 1 entry
        encodeString("_pd", into: &out)
        encodeBytes(tlvData, into: &out)
        return out
    }

    /// Wrap raw TLV8 bytes for psStart — `{"_pd": data, "_pwTy": 1}`.
    /// `_pwTy: 1` triggers PIN display on the Apple TV.
    static func wrapPsStartData(_ tlvData: Data) -> Data {
        var out = Data()
        out.append(0xE2)                    // dict, 2 entries
        encodeString("_pd", into: &out)
        encodeBytes(tlvData, into: &out)
        encodeString("_pwTy", into: &out)
        out.append(0x09)                    // small int: 1
        return out
    }

    /// Wrap raw TLV8 bytes for psNext (M3/M5) — `{"_pd": data, "_pwTy": 1}`.
    static func wrapPsNextData(_ tlvData: Data) -> Data {
        var out = Data()
        out.append(0xE2)                    // dict, 2 entries
        encodeString("_pd", into: &out)
        encodeBytes(tlvData, into: &out)
        encodeString("_pwTy", into: &out)
        out.append(0x09)                    // small int: 1
        return out
    }

    /// Wrap raw TLV8 bytes for pvStart — `{"_pd": data, "_auTy": 4}`.
    /// `_auTy: 4` tells the ATV this is a HAP pair-verify request.
    static func wrapPvStartData(_ tlvData: Data) -> Data {
        var out = Data()
        out.append(0xE2)                    // dict, 2 entries
        encodeString("_pd", into: &out)
        encodeBytes(tlvData, into: &out)
        encodeString("_auTy", into: &out)
        out.append(0x0C)                    // small int: 4 (0x08 + 4)
        return out
    }

    /// Extract the `_pd` bytes value from an OPACK dict, or nil if not found.
    static func extractPairingData(from opack: Data) -> Data? {
        var cursor = opack.startIndex
        guard let count = readDictHeader(opack, cursor: &cursor) else { return nil }
        for _ in 0..<count {
            guard let key = readString(opack, cursor: &cursor) else { break }
            if key == "_pd" {
                return readBytes(opack, cursor: &cursor)
            }
            skipValue(opack, cursor: &cursor)
        }
        return nil
    }

    // MARK: - Encoding

    private static func encodeString(_ s: String, into out: inout Data) {
        let b = Data(s.utf8)
        if b.count <= 0x1F {
            out.append(UInt8(0x40 + b.count))
        } else {
            out.append(0x60)
            out.append(UInt8(b.count & 0xFF))
        }
        out.append(contentsOf: b)
    }

    private static func encodeBytes(_ data: Data, into out: inout Data) {
        let n = data.count
        if n <= 0x1F {
            out.append(UInt8(0x70 + n))
        } else if n <= 0xFF {
            out.append(0x91)
            out.append(UInt8(n))
        } else {
            // 0x92: 2-byte little-endian length (Companion OPACK convention)
            out.append(0x92)
            out.append(UInt8(n & 0xFF))
            out.append(UInt8((n >> 8) & 0xFF))
        }
        out.append(contentsOf: data)
    }

    // MARK: - Decoding

    private static func readDictHeader(_ data: Data, cursor: inout Data.Index) -> Int? {
        guard cursor < data.endIndex else { return nil }
        let tag = data[cursor]
        guard tag >= 0xE0, tag <= 0xEF else { return nil }
        data.formIndex(after: &cursor)
        return Int(tag - 0xE0)
    }

    private static func readString(_ data: Data, cursor: inout Data.Index) -> String? {
        guard cursor < data.endIndex else { return nil }
        let tag = data[cursor]
        data.formIndex(after: &cursor)

        var length: Int
        switch tag {
        case 0x40...0x5F:
            length = Int(tag - 0x40)
        case 0x60:
            guard cursor < data.endIndex else { return nil }
            length = Int(data[cursor]); data.formIndex(after: &cursor)
        default:
            return nil
        }
        guard data.index(cursor, offsetBy: length, limitedBy: data.endIndex) != nil,
              cursor.advanced(by: length) <= data.endIndex else { return nil }
        let end = data.index(cursor, offsetBy: length)
        let s = String(data: data[cursor..<end], encoding: .utf8)
        cursor = end
        return s
    }

    private static func readBytes(_ data: Data, cursor: inout Data.Index) -> Data? {
        guard cursor < data.endIndex else { return nil }
        let tag = data[cursor]
        data.formIndex(after: &cursor)

        var length: Int
        switch tag {
        case 0x70...0x8F:
            length = Int(tag - 0x70)
        case 0x90, 0x91:
            // 1-byte length: 0x90 and 0x91 both use a single length byte
            // (empirically confirmed: ATV sends 0x91 for medium-sized payloads)
            guard cursor < data.endIndex else { return nil }
            length = Int(data[cursor]); data.formIndex(after: &cursor)
        case 0x92:
            // 2-byte little-endian length (Companion OPACK convention)
            guard data.distance(from: cursor, to: data.endIndex) >= 2 else { return nil }
            length = Int(data[cursor]) | Int(data[data.index(cursor, offsetBy: 1)]) << 8
            data.formIndex(&cursor, offsetBy: 2)
        default:
            return nil
        }
        guard data.distance(from: cursor, to: data.endIndex) >= length else { return nil }
        let end = data.index(cursor, offsetBy: length)
        let result = Data(data[cursor..<end])
        cursor = end
        return result
    }

    private static func skipValue(_ data: Data, cursor: inout Data.Index) {
        guard cursor < data.endIndex else { return }
        let tag = data[cursor]
        data.formIndex(after: &cursor)
        switch tag {
        case 0x01, 0x02, 0x04:   break                          // bool/null
        case 0x08...0x2F:         break                          // small int
        case 0x30:                advance(&cursor, by: 1, in: data)
        case 0x31:                advance(&cursor, by: 2, in: data)
        case 0x32, 0x35:          advance(&cursor, by: 4, in: data)
        case 0x33, 0x36:          advance(&cursor, by: 8, in: data)
        case 0x40...0x5F:         advance(&cursor, by: Int(tag - 0x40), in: data)
        case 0x60:
            if cursor < data.endIndex { let n = Int(data[cursor]); data.formIndex(after: &cursor); advance(&cursor, by: n, in: data) }
        case 0x70...0x8F:         advance(&cursor, by: Int(tag - 0x70), in: data)
        case 0x90, 0x91:
            if cursor < data.endIndex { let n = Int(data[cursor]); data.formIndex(after: &cursor); advance(&cursor, by: n, in: data) }
        case 0x92:
            if data.distance(from: cursor, to: data.endIndex) >= 2 {
                let n = Int(data[cursor]) | Int(data[data.index(cursor, offsetBy: 1)]) << 8
                data.formIndex(&cursor, offsetBy: 2); advance(&cursor, by: n, in: data)
            }
        case 0xD0...0xDF:
            let count = Int(tag - 0xD0)
            for _ in 0..<count { skipValue(data, cursor: &cursor) }
        case 0xE0...0xEF:
            let count = Int(tag - 0xE0) * 2  // key + value per entry
            for _ in 0..<count { skipValue(data, cursor: &cursor) }
        default: break
        }
    }

    private static func advance(_ cursor: inout Data.Index, by n: Int, in data: Data) {
        let limit = data.endIndex
        _ = data.formIndex(&cursor, offsetBy: n, limitedBy: limit)
    }
}
