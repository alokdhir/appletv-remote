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
///   0x31         uint16 (2 bytes, little-endian)
///   0x32         uint32 (4 bytes, little-endian)
///   0x33         uint64 (8 bytes)
///   0x40–0x5F    string, length = byte - 0x40  (0–31 UTF-8 bytes)
///   0x60         string, 1-byte length follows
///   0x70–0x8F    bytes,  length = byte - 0x70  (0–31 bytes)
///   0x90         bytes,  1-byte length follows
///   0x91         bytes,  1-byte length follows  (ATV uses this; treated same as 0x90)
///   0x92         bytes,  2-byte little-endian length follows
///   0x93         bytes,  4-byte little-endian length follows
///   0xD0–0xDF    array,  count = byte - 0xD0   (0–15 items)
///   0xE0–0xEF    dict,   count = byte - 0xE0   (0–15 key-value pairs)
public enum OPACK {

    private static func encodeUInt32(_ value: UInt32, into out: inout Data) {
        out.append(0x32)
        out.append(UInt8( value        & 0xFF))
        out.append(UInt8((value >> 8)  & 0xFF))
        out.append(UInt8((value >> 16) & 0xFF))
        out.append(UInt8((value >> 24) & 0xFF))
    }

    // MARK: - General OPACK encoder

    /// Encode any Swift value into OPACK bytes.
    /// Supports: String, Int, UInt32, Bool, Data, [String: Any], [Any].
    public static func pack(_ value: Any) -> Data {
        var out = Data()
        packValue(value, into: &out)
        return out
    }

    private static func packValue(_ value: Any, into out: inout Data) {
        switch value {
        case is NSNull:
            out.append(0x04)  // OPACK null tag (pyatv support/opack.py)
        case let s as String:
            encodeString(s, into: &out)
        case let i as Int:
            encodeInt(i, into: &out)
        case let u as UInt32:
            encodeInt(Int(u), into: &out)
        case let u as UInt64:
            if u <= UInt64(Int64.max) {
                encodeInt(Int(u), into: &out)
            } else {
                out.append(0x33)
                appendLittleEndian(u, byteCount: 8, into: &out)
            }
        case let d as Data:
            encodeBytes(d, into: &out)
        case let b as Bool:
            out.append(b ? 0x01 : 0x02)
        case let dict as [String: Any]:
            // OPACK dicts with 0–15 entries are encoded inline with tag 0xE0+count.
            // We don't currently emit a variable-length form, so larger dicts are
            // a programming error (silent truncation was the old behavior — now fails loud).
            precondition(dict.count <= 15, "OPACK dict with > 15 entries is not supported")
            out.append(UInt8(0xE0 + dict.count))
            // Sort keys lexicographically so the wire output is deterministic —
            // Swift Dictionary iteration order is otherwise unspecified.
            for k in dict.keys.sorted() {
                encodeString(k, into: &out)
                packValue(dict[k]!, into: &out)
            }
        case let arr as [Any]:
            precondition(arr.count <= 15, "OPACK array with > 15 entries is not supported")
            out.append(UInt8(0xD0 + arr.count))
            for item in arr { packValue(item, into: &out) }
        default:
            assertionFailure("OPACK.packValue: unsupported type \(type(of: value))")
            out.append(0x04)  // null — safe fallback in release builds
        }
    }

    /// Encode a Swift Int using the narrowest OPACK tag that exactly represents it.
    ///
    ///   0x08..0x2F   small int 0–39
    ///   0x30         uint8   (40..255)
    ///   0x31         uint16  (256..65535, little-endian)
    ///   0x32         uint32  (65536..UInt32.max, little-endian)
    ///   0x33         uint64  (values above UInt32.max, little-endian)
    ///   0x36         int64   (any negative, two's complement little-endian)
    ///
    /// Pre-fix behavior clamped to Int32 range via UInt32(bitPattern: Int32(clamping:)),
    /// which silently corrupted negatives (−1 → 0xFFFFFFFF = +4294967295) and large
    /// positives (Int64 overflow clamped to Int32.max).
    private static func encodeInt(_ i: Int, into out: inout Data) {
        if i >= 0 {
            if i <= 0x27 {
                out.append(UInt8(0x08 + i))
            } else if i <= 0xFF {
                out.append(0x30)
                out.append(UInt8(i))
            } else if i <= 0xFFFF {
                out.append(0x31)
                appendLittleEndian(UInt64(i), byteCount: 2, into: &out)
            } else if i <= 0xFFFF_FFFF {
                out.append(0x32)
                appendLittleEndian(UInt64(i), byteCount: 4, into: &out)
            } else {
                out.append(0x33)
                appendLittleEndian(UInt64(i), byteCount: 8, into: &out)
            }
        } else {
            // Negative → signed 64-bit (0x36), two's complement big-endian.
            out.append(0x36)
            appendLittleEndian(UInt64(bitPattern: Int64(i)), byteCount: 8, into: &out)
        }
    }

    private static func appendLittleEndian(_ value: UInt64, byteCount: Int, into out: inout Data) {
        for offset in stride(from: 0, through: (byteCount - 1) * 8, by: 8) {
            out.append(UInt8((value >> offset) & 0xFF))
        }
    }

    // MARK: - Session message helpers

    /// Encode a `_heartbeat` response (type=3) when the ATV initiates the heartbeat.
    public static func encodeHeartbeatResponse(txn: UInt32) -> Data {
        var out = Data()
        out.append(0xE3)              // dict, 3 entries
        encodeString("_i", into: &out)
        encodeString("_heartbeat", into: &out)
        encodeString("_t", into: &out)
        out.append(0x08 + 3)          // small int: 3 (response)
        encodeString("_x", into: &out)
        encodeUInt32(txn, into: &out)
        return out
    }

    /// Encode a `_pong` response to an ATV `_ping` request.
    /// _t: 3 = response (ATV sends _ping as _t: 2 request, expects _t: 3 response).
    public static func encodePong(txn: UInt32) -> Data {
        var out = Data()
        out.append(0xE3)              // dict, 3 entries
        encodeString("_i", into: &out)
        encodeString("_pong", into: &out)
        encodeString("_t", into: &out)
        out.append(0x08 + 3)          // small int: 3 (response)
        encodeString("_x", into: &out)
        encodeUInt32(txn, into: &out)
        return out
    }

    /// Encode `_systemInfo` request — tells the ATV who we are.
    public static func encodeSystemInfo(clientID: String, rpID: String, name: String, txn: UInt32) -> Data {
        pack([
            "_i": "_systemInfo",
            "_t": 2,
            "_x": txn,
            // `_pubID`, `model`, `name` mimic pyatv's defaults. ATV appears
            // to gate some features (e.g. FetchLaunchableApplicationsEvent)
            // on client identity fields; pyatv-matching values are known to
            // be accepted.
            //
            // `_pubID` = "FF:" + hex of "pyatv" (see pyatv settings.py
            // DEFAULT_DEVICE_ID). It is a MAC-address-shaped identifier,
            // NOT a UUID.
            "_c": [
                "_bf":   0,
                "_cf":   512,
                "_clFl": 128,
                // pyatv sends `_i: None` (null) in `_systemInfo` — NOT the rpID.
                // The ATV's own rp_id comes back in the response; this field in the
                // request is intentionally null per pyatv's wire format.
                "_i":    NSNull(),
                "_idsID": Data(clientID.utf8),
                "_pubID": "FF:70:79:61:74:76",
                "_sf":   256,
                "_sv":   "170.18",
                "model": "iPhone10,6",
                // MUST match the name sent in HAP pair-setup M5 (HAPPairing.swift).
                // ATV stores the client name during pairing and gates some features
                // (e.g. FetchLaunchableApplicationsEvent) on connect-time name match.
                // TEMP: impersonating pyatv for Option-D test — pyatv's default name.
                "name":  name,
            ] as [String: Any],
        ] as [String: Any])
    }

    /// Encode `_touchStart` request — part of the Companion session handshake.
    /// The ATV expects this between `_systemInfo` and `_sessionStart`; without
    /// it the session setup is incomplete and the ATV closes the socket after
    /// ~35 s. Matches pyatv's CompanionAPI._touch_start (api.py:450-453).
    public static func encodeTouchStart(txn: UInt32) -> Data {
        pack([
            "_i": "_touchStart",
            "_t": 2,
            "_x": txn,
            "_c": [
                "_height": 1000,
                "_tFl":    0,
                "_width":  1000,
            ] as [String: Any],
        ] as [String: Any])
    }

    /// Encode a `_hidT` touch event — one frame in a swipe gesture sequence.
    ///
    /// Coordinates are in the 1000×1000 space declared by `_touchStart`.
    /// - `phase`: 1 = press (begin), 3 = hold (move), 4 = release (end)
    /// - `nanoseconds`: ns elapsed since `_touchStart` was sent (pyatv's _base_timestamp).
    ///
    /// No `_x` transaction field — pyatv fires these as fire-and-forget events.
    /// Matches pyatv's `hid_event()` / `_send_event("_hidT", ...)` in companion/api.py.
    public static func encodeTouchEvent(x: Double, y: Double, phase: Int,
                                        txn: UInt32, nanoseconds: UInt64) -> Data {
        pack([
            "_i": "_hidT",
            "_t": 1,
            "_x": txn,
            "_c": [
                "_cx":  Int(x),
                "_cy":  Int(y),
                "_tPh": phase,
                "_tFg": 1,
                "_ns":  nanoseconds,
            ] as [String: Any],
        ] as [String: Any])
    }

    /// Encode a `_touchStop` frame — closes the touch session.
    public static func encodeTouchStop(txn: UInt32) -> Data {
        pack([
            "_i": "_touchStop",
            "_t": 2,
            "_x": txn,
            "_c": ["_i": 1] as [String: Any],
        ] as [String: Any])
    }

    /// Encode a HID button command (`_hidC`).
    /// - Parameters:
    ///   - keycode: HID keycode for the button.
    ///   - state: 1 = button down, 2 = button up.
    ///   - txn: Transaction counter value.
    public static func encodeHIDCommand(keycode: UInt8, state: Int, txn: UInt32) -> Data {
        pack([
            "_i": "_hidC", "_t": 2, "_x": txn,
            "_c": ["_hBtS": state, "_hidC": Int(keycode)] as [String: Any],
        ] as [String: Any])
    }

    /// Encode `_tiStart` (text input start) request — sent between
    /// `_sessionStart` and `_interest`. Empty content payload.
    /// Matches pyatv's CompanionAPI._text_input_start (api.py:385).
    public static func encodeTextInputStart(txn: UInt32) -> Data {
        pack([
            "_i": "_tiStart",
            "_t": 2,
            "_x": txn,
            "_c": [String: Any](),
        ] as [String: Any])
    }

    /// Encode `_tiStop` — tears down the active text input session.
    /// Sent as a request (_t:2) before a fresh _tiStart.
    public static func encodeTextInputStop(txn: UInt32) -> Data {
        pack([
            "_i": "_tiStop",
            "_t": 2,
            "_x": txn,
            "_c": [String: Any](),
        ] as [String: Any])
    }

    /// Encode `_tiC` — fire-and-forget event (_t:1) that sends text to the ATV.
    /// `tiD` is the RTI binary plist payload from RTITextOperations.
    public static func encodeTextInputCommand(tiD: Data, txn: UInt32) -> Data {
        pack([
            "_i": "_tiC",
            "_t": 1,
            "_x": txn,
            "_c": [
                "_tiV": 1,
                "_tiD": tiD,
            ] as [String: Any],
        ] as [String: Any])
    }

    /// Encode a `FetchAttentionState` Request — a cheap status poll pyatv
    /// uses as the closest thing to a heartbeat. The ATV responds with
    /// `_c.state` (an Int), which gives us the reply traffic needed to
    /// refresh its idle timer. Without periodic traffic like this the ATV
    /// drops idle Companion sockets at ~38 s.
    public static func encodeFetchAttentionState(txn: UInt32) -> Data {
        pack([
            "_i": "FetchAttentionState",
            "_t": 2,
            "_x": txn,
            "_c": [String: Any](),
        ] as [String: Any])
    }

    /// Fetch list of launchable apps from the ATV.
    public static func encodeFetchLaunchableApplicationsEvent(txn: UInt32) -> Data {
        pack([
            "_i": "FetchLaunchableApplicationsEvent",
            "_t": 2,
            "_x": txn,
            "_c": [String: Any](),
        ] as [String: Any])
    }

    /// Launch an app by bundle ID.
    public static func encodeLaunchApp(bundleID: String, txn: UInt32) -> Data {
        pack([
            "_i": "_launchApp",
            "_t": 2,
            "_x": txn,
            "_c": ["_bundleID": bundleID],
        ] as [String: Any])
    }

    /// Encode `_sessionStart` request.
    public static func encodeSessionStart(txn: UInt32, localSID: UInt32) -> Data {
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

    /// Encode `_interest` event subscription — tells the ATV we want to be
    /// notified of events of a given type (e.g. `_iMC` for media control).
    ///
    /// `_t: 1` marks this as an Event (fire-and-forget, not a request), so the
    /// ATV does not send a response. Once subscribed, the ATV pushes event
    /// frames whenever the subscribed state changes, and that inbound traffic
    /// keeps the connection's app-level idle timer from firing — which is why
    /// pyatv-style clients never need a periodic keepalive.
    public static func encodeInterest(events: [String], txn: UInt32) -> Data {
        pack([
            "_i": "_interest",
            "_t": 1,    // Event (fire-and-forget) — ATV silently ignores _t:2 for _interest
            "_x": txn,
            "_c": [
                "_regEvents": events as [Any],
            ] as [String: Any],
        ] as [String: Any])
    }

    // MARK: - Decoding

    /// Decode a top-level OPACK dict into [String: Any].
    /// Supports string, float, int, bytes, bool, and nested dict values.
    /// Handles both fixed-count dicts (0xE0+N for N≤14) and open-ended dicts
    /// (0xEF with a 0x03 terminator, used by the ATV for app lists).
    public static func decodeDict(_ data: Data) -> [String: Any]? {
        var cursor = data.startIndex
        guard cursor < data.endIndex else { return nil }
        let tag = data[cursor]
        guard tag >= 0xE0, tag <= 0xEF else { return nil }
        data.formIndex(after: &cursor)
        let count = Int(tag - 0xE0)
        let isOpen = count == 0xF  // 0xEF = open-ended, terminated by 0x03
        var result = [String: Any]()
        var iterations = 0
        while true {
            if isOpen {
                // Check for terminator 0x03
                if cursor < data.endIndex, data[cursor] == 0x03 { break }
            } else {
                if iterations >= count { break }
            }
            guard let key = readString(data, cursor: &cursor) else { break }
            if let s = peekString(data, cursor: &cursor) {
                result[key] = s
            } else if let f = peekDouble(data, cursor: &cursor) {
                result[key] = f
            } else if let i = peekInt(data, cursor: &cursor) {
                result[key] = i
            } else if let b = peekBytes(data, cursor: &cursor) {
                result[key] = b
            } else if let d = peekNestedDict(data, cursor: &cursor) {
                result[key] = d
            } else {
                skipValue(data, cursor: &cursor)
            }
            iterations += 1
        }
        return result
    }

    /// Fast shallow decode: reads only scalar top-level values (string, int, bool,
    /// bytes). Nested dicts and arrays are skipped. Used for large messages like
    /// the 7KB _systemInfo response where full recursive decoding is too expensive.
    public static func decodeDictShallow(_ data: Data) -> [String: Any]? {
        var cursor = data.startIndex
        guard cursor < data.endIndex else { return nil }
        let tag = data[cursor]
        guard tag >= 0xE0, tag <= 0xEF else { return nil }
        data.formIndex(after: &cursor)
        let count = Int(tag - 0xE0)
        let isOpen = count == 0xF
        var result = [String: Any]()
        var iterations = 0
        while true {
            if isOpen {
                if cursor >= data.endIndex || data[cursor] == 0x03 { break }
            } else {
                if iterations >= count { break }
            }
            let before = cursor
            guard let key = readString(data, cursor: &cursor) else { break }
            if let s = peekString(data, cursor: &cursor) {
                result[key] = s
            } else if let i = peekInt(data, cursor: &cursor) {
                result[key] = i
            } else if let f = peekDouble(data, cursor: &cursor) {
                result[key] = f
            } else if let b = peekBytes(data, cursor: &cursor) {
                result[key] = b
            } else {
                skipValue(data, cursor: &cursor)  // skip nested dicts/arrays
            }
            if cursor == before { break }
            iterations += 1
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
            guard let u = readLittleEndianUInt(data, cursor: cursor, byteCount: 1) else { return nil }
            data.formIndex(&cursor, offsetBy: 2)
            return Int(u)
        case 0x31:
            guard let u = readLittleEndianUInt(data, cursor: cursor, byteCount: 2) else { return nil }
            data.formIndex(&cursor, offsetBy: 3)
            return Int(u)
        case 0x32:
            guard let u = readLittleEndianUInt(data, cursor: cursor, byteCount: 4) else { return nil }
            data.formIndex(&cursor, offsetBy: 5)
            return Int(u)
        case 0x33:
            guard let u = readLittleEndianUInt(data, cursor: cursor, byteCount: 8) else { return nil }
            data.formIndex(&cursor, offsetBy: 9)
            // On 64-bit platforms Int == Int64, so values above Int64.max round-trip lossily.
            // Our encoder never emits such values (they come from Swift Int input).
            return Int(bitPattern: UInt(u))
        case 0x35:
            // int32, signed little-endian
            guard let u = readLittleEndianUInt(data, cursor: cursor, byteCount: 4) else { return nil }
            data.formIndex(&cursor, offsetBy: 5)
            return Int(Int32(bitPattern: UInt32(u)))
        case 0x36:
            // int64, signed little-endian
            guard let u = readLittleEndianUInt(data, cursor: cursor, byteCount: 8) else { return nil }
            data.formIndex(&cursor, offsetBy: 9)
            return Int(Int64(bitPattern: u))
        default: return nil
        }
    }

    /// Reads `byteCount` little-endian bytes starting at `cursor + 1` (skipping the tag
    /// byte at `cursor`). Returns nil if the slice is out of bounds. Does NOT advance
    /// the cursor — callers do that themselves after consuming the value.
    private static func readLittleEndianUInt(_ data: Data,
                                             cursor: Data.Index,
                                             byteCount: Int) -> UInt64? {
        guard data.distance(from: cursor, to: data.endIndex) >= 1 + byteCount else { return nil }
        var v: UInt64 = 0
        for offset in stride(from: byteCount, through: 1, by: -1) {
            v = (v << 8) | UInt64(data[data.index(cursor, offsetBy: offset)])
        }
        return v
    }

    private static func peekDouble(_ data: Data, cursor: inout Data.Index) -> Double? {
        let saved = cursor
        guard cursor < data.endIndex else { return nil }
        let tag = data[cursor]
        data.formIndex(after: &cursor)
        switch tag {
        case 0x06:  // float32 big-endian IEEE 754
            guard data.distance(from: cursor, to: data.endIndex) >= 4 else { cursor = saved; return nil }
            var bits: UInt32 = 0
            for i in 0..<4 { bits = (bits << 8) | UInt32(data[data.index(cursor, offsetBy: i)]) }
            data.formIndex(&cursor, offsetBy: 4)
            return Double(Float(bitPattern: bits))
        case 0x07:  // float64 big-endian IEEE 754
            guard data.distance(from: cursor, to: data.endIndex) >= 8 else { cursor = saved; return nil }
            var bits: UInt64 = 0
            for i in 0..<8 { bits = (bits << 8) | UInt64(data[data.index(cursor, offsetBy: i)]) }
            data.formIndex(&cursor, offsetBy: 8)
            return Double(bitPattern: bits)
        default:
            cursor = saved; return nil
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
        if let d = decodeDict(data[cursor...]) {
            // advance cursor: re-decode to know how many bytes were consumed
            data.formIndex(after: &cursor)  // skip the tag byte
            let count = Int(tag - 0xE0)
            let isOpen = count == 0xF
            var iterations = 0
            while true {
                if isOpen {
                    if cursor < data.endIndex, data[cursor] == 0x03 {
                        data.formIndex(after: &cursor); break
                    }
                } else {
                    if iterations >= count { break }
                }
                skipValue(data, cursor: &cursor)  // key
                skipValue(data, cursor: &cursor)  // value
                iterations += 1
            }
            return d
        }
        cursor = saved; return nil
    }

    // MARK: - Pairing helpers

    /// Encode `{"name": displayName}` for the Companion-specific TLV8 tag=0x11 in pair-setup M5.
    /// This registers the controller in the Companion controller store on the ATV, which is the
    /// store checked during pair-verify. Without it, the ATV stores us in HAP-only and rejects
    /// pair-verify M3 with error=2 (Authentication).
    public static func encodeDeviceName(_ displayName: String) -> Data {
        var out = Data()
        out.append(0xE1)   // dict, 1 entry
        encodeString("name", into: &out)
        encodeString(displayName, into: &out)
        return out
    }

    /// Wrap raw TLV8 bytes in `{"_pd": data}` for pvNext frames.
    public static func wrapPairingData(_ tlvData: Data) -> Data {
        var out = Data()
        out.append(0xE1)                    // dict, 1 entry
        encodeString("_pd", into: &out)
        encodeBytes(tlvData, into: &out)
        return out
    }

    /// Wrap raw TLV8 bytes for psStart — `{"_pd": data, "_pwTy": 1}`.
    /// `_pwTy: 1` triggers PIN display on the Apple TV.
    public static func wrapPsStartData(_ tlvData: Data) -> Data {
        var out = Data()
        out.append(0xE2)                    // dict, 2 entries
        encodeString("_pd", into: &out)
        encodeBytes(tlvData, into: &out)
        encodeString("_pwTy", into: &out)
        out.append(0x09)                    // small int: 1
        return out
    }

    /// Wrap raw TLV8 bytes for psNext (M3/M5) — `{"_pd": data, "_pwTy": 1}`.
    public static func wrapPsNextData(_ tlvData: Data) -> Data {
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
    public static func wrapPvStartData(_ tlvData: Data) -> Data {
        var out = Data()
        out.append(0xE2)                    // dict, 2 entries
        encodeString("_pd", into: &out)
        encodeBytes(tlvData, into: &out)
        encodeString("_auTy", into: &out)
        out.append(0x0C)                    // small int: 4 (0x08 + 4)
        return out
    }

    /// Extract the `_pd` bytes value from an OPACK dict, or nil if not found.
    public static func extractPairingData(from opack: Data) -> Data? {
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
        if b.count <= 0x20 {
            out.append(UInt8(0x40 + b.count))
        } else if b.count <= 0xFF {
            out.append(0x61)
            out.append(UInt8(b.count & 0xFF))
        } else {
            out.append(0x62)
            out.append(UInt8(b.count & 0xFF))
            out.append(UInt8((b.count >> 8) & 0xFF))
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
        } else if n <= 0xFFFF {
            out.append(0x92)
            out.append(UInt8(n & 0xFF))
            out.append(UInt8((n >> 8) & 0xFF))
        } else {
            precondition(n <= 0xFFFF_FFFF, "OPACK bytes > 4 GiB not supported")
            out.append(0x93)
            out.append(UInt8( n        & 0xFF))
            out.append(UInt8((n >>  8) & 0xFF))
            out.append(UInt8((n >> 16) & 0xFF))
            out.append(UInt8((n >> 24) & 0xFF))
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
        case 0x40...0x60:
            length = Int(tag - 0x40)
        case 0x61:
            guard cursor < data.endIndex else { return nil }
            length = Int(data[cursor]); data.formIndex(after: &cursor)
        case 0x62:
            guard data.distance(from: cursor, to: data.endIndex) >= 2 else { return nil }
            length = Int(data[cursor]) | (Int(data[data.index(cursor, offsetBy: 1)]) << 8)
            data.formIndex(&cursor, offsetBy: 2)
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
        case 0x93:
            guard data.distance(from: cursor, to: data.endIndex) >= 4 else { return nil }
            length =  Int(data[cursor])
                   | (Int(data[data.index(cursor, offsetBy: 1)]) <<  8)
                   | (Int(data[data.index(cursor, offsetBy: 2)]) << 16)
                   | (Int(data[data.index(cursor, offsetBy: 3)]) << 24)
            data.formIndex(&cursor, offsetBy: 4)
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
        case 0x06:                advance(&cursor, by: 4, in: data) // float32
        case 0x07:                advance(&cursor, by: 8, in: data) // float64
        case 0x08...0x2F:         break                          // small int
        case 0x30:                advance(&cursor, by: 1, in: data)
        case 0x31:                advance(&cursor, by: 2, in: data)
        case 0x32, 0x35:          advance(&cursor, by: 4, in: data)
        case 0x33, 0x36:          advance(&cursor, by: 8, in: data)
        case 0x40...0x60:         advance(&cursor, by: Int(tag - 0x40), in: data)
        case 0x61:
            if cursor < data.endIndex { let n = Int(data[cursor]); data.formIndex(after: &cursor); advance(&cursor, by: n, in: data) }
        case 0x62:
            if data.distance(from: cursor, to: data.endIndex) >= 2 {
                let n = Int(data[cursor]) | Int(data[data.index(cursor, offsetBy: 1)]) << 8
                data.formIndex(&cursor, offsetBy: 2); advance(&cursor, by: n, in: data)
            }
        case 0x70...0x8F:         advance(&cursor, by: Int(tag - 0x70), in: data)
        case 0x90, 0x91:
            if cursor < data.endIndex { let n = Int(data[cursor]); data.formIndex(after: &cursor); advance(&cursor, by: n, in: data) }
        case 0x92:
            if data.distance(from: cursor, to: data.endIndex) >= 2 {
                let n = Int(data[cursor]) | Int(data[data.index(cursor, offsetBy: 1)]) << 8
                data.formIndex(&cursor, offsetBy: 2); advance(&cursor, by: n, in: data)
            }
        case 0x93:
            if data.distance(from: cursor, to: data.endIndex) >= 4 {
                let n =  Int(data[cursor])
                      | (Int(data[data.index(cursor, offsetBy: 1)]) <<  8)
                      | (Int(data[data.index(cursor, offsetBy: 2)]) << 16)
                      | (Int(data[data.index(cursor, offsetBy: 3)]) << 24)
                data.formIndex(&cursor, offsetBy: 4); advance(&cursor, by: n, in: data)
            }
        case 0xD0...0xDF:
            let count = Int(tag - 0xD0)
            for _ in 0..<count { skipValue(data, cursor: &cursor) }
        case 0xE0...0xEF:
            let count = Int(tag - 0xE0)
            if count == 0xF {
                // open-ended dict: skip key-value pairs until 0x03 terminator
                while cursor < data.endIndex, data[cursor] != 0x03 {
                    let before = cursor
                    skipValue(data, cursor: &cursor)  // key
                    skipValue(data, cursor: &cursor)  // value
                    if cursor == before { break }     // guard: stuck cursor → corrupt data
                }
                if cursor < data.endIndex { data.formIndex(after: &cursor) }  // consume 0x03
            } else {
                for _ in 0..<(count * 2) { skipValue(data, cursor: &cursor) }
            }
        default: break
        }
    }

    private static func advance(_ cursor: inout Data.Index, by n: Int, in data: Data) {
        let limit = data.endIndex
        _ = data.formIndex(&cursor, offsetBy: n, limitedBy: limit)
    }
}
