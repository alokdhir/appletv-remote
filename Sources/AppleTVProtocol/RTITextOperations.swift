import Foundation

/// Builds and parses the RTI (Remote Text Input) binary plist payloads
/// used in Companion `_tiC` events.
///
/// The payload is an NSKeyedArchiver-encoded plist containing an
/// `RTITextOperations` object — matching pyatv's
/// `plist_payloads/rti_text_operations.py` exactly.
public enum RTITextOperations {

    // MARK: - Encode

    /// Build a payload that inserts `text` at the current cursor position.
    public static func inputPayload(sessionUUID: Data, text: String) -> Data {
        let plist: [String: Any] = [
            "$version":  100000,
            "$archiver": "RTIKeyedArchiver",
            "$top": ["textOperations": plistUID(1)],
            "$objects": [
                "$null",
                // Index 1 — RTITextOperations instance
                [
                    "keyboardOutput":    plistUID(2),
                    "$class":            plistUID(7),
                    "targetSessionUUID": plistUID(5),
                ] as [String: Any],
                // Index 2 — TIKeyboardOutput instance (with insertionText)
                [
                    "insertionText": plistUID(3),
                    "$class":        plistUID(4),
                ] as [String: Any],
                text,   // Index 3 — the text to insert
                // Index 4 — TIKeyboardOutput class
                ["$classname": "TIKeyboardOutput",
                 "$classes":   ["TIKeyboardOutput", "NSObject"]] as [String: Any],
                // Index 5 — NSUUID instance
                ["NS.uuidbytes": sessionUUID,
                 "$class":       plistUID(6)] as [String: Any],
                // Index 6 — NSUUID class
                ["$classname": "NSUUID",
                 "$classes":   ["NSUUID", "NSObject"]] as [String: Any],
                // Index 7 — RTITextOperations class
                ["$classname": "RTITextOperations",
                 "$classes":   ["RTITextOperations", "NSObject"]] as [String: Any],
            ] as [Any],
        ]
        return try! PropertyListSerialization.data(fromPropertyList: plist,
                                                   format: .binary,
                                                   options: 0)
    }

    /// Build a payload that clears the current field content.
    public static func clearPayload(sessionUUID: Data) -> Data {
        let plist: [String: Any] = [
            "$version":  100000,
            "$archiver": "RTIKeyedArchiver",
            "$top": ["textOperations": plistUID(1)],
            "$objects": [
                "$null",
                // Index 1 — RTITextOperations instance (with textToAssert = "")
                [
                    "$class":            plistUID(7),
                    "targetSessionUUID": plistUID(5),
                    "keyboardOutput":    plistUID(2),
                    "textToAssert":      plistUID(4),
                ] as [String: Any],
                // Index 2 — TIKeyboardOutput instance (empty)
                ["$class": plistUID(3)] as [String: Any],
                // Index 3 — TIKeyboardOutput class
                ["$classname": "TIKeyboardOutput",
                 "$classes":   ["TIKeyboardOutput", "NSObject"]] as [String: Any],
                "",     // Index 4 — empty text assertion
                // Index 5 — NSUUID instance
                ["NS.uuidbytes": sessionUUID,
                 "$class":       plistUID(6)] as [String: Any],
                // Index 6 — NSUUID class
                ["$classname": "NSUUID",
                 "$classes":   ["NSUUID", "NSObject"]] as [String: Any],
                // Index 7 — RTITextOperations class
                ["$classname": "RTITextOperations",
                 "$classes":   ["RTITextOperations", "NSObject"]] as [String: Any],
            ] as [Any],
        ]
        return try! PropertyListSerialization.data(fromPropertyList: plist,
                                                   format: .binary,
                                                   options: 0)
    }

    // MARK: - Decode (session UUID extraction)

    /// Extract the session UUID from the `_tiD` binary plist returned by `_tiStart`.
    ///
    /// Walks the NSKeyedArchiver object graph by following:
    ///   `$top.sessionUUID` → UID → `$objects[uid]` → `NS.uuidbytes`
    ///
    /// Does NOT assume fixed object indices — follows the UID chain.
    public static func extractSessionUUID(from tiD: Data) -> Data? {
        guard let plist = try? PropertyListSerialization.propertyList(from: tiD,
                                                                       format: nil) as? [String: Any],
              let objects = plist["$objects"] as? [Any],
              let top     = plist["$top"]     as? [String: Any] else { return nil }

        guard let uid = top["sessionUUID"],
              let idx = uidIndex(uid),
              idx < objects.count else { return nil }

        let obj = objects[idx]

        // tvOS serialises the session UUID as a plain Data (16 bytes) at the UID index.
        if let data = obj as? Data, data.count == 16 { return data }

        // Fallback: some archiver versions wrap it in an NSUUID dict with NS.uuidbytes.
        if let dict = obj as? [String: Any], let bytes = dict["NS.uuidbytes"] as? Data {
            return bytes
        }

        return nil
    }

    // MARK: - Private helpers

    /// Create an NSKeyedArchiver UID reference (CF$UID dict).
    private static func plistUID(_ value: Int) -> [String: Any] {
        ["CF$UID": value]
    }

    /// Extract the integer index from a UID.
    /// PropertyListSerialization returns CFKeyedArchiverUID as an opaque __NSCFType
    /// whose description is "<CFKeyedArchiverUID 0x...>{value = N}".
    /// We parse N from that string; fall back to CF$UID dict for any future format.
    private static func uidIndex(_ uid: Any) -> Int? {
        // Most common: opaque CFKeyedArchiverUID — parse from description
        let desc = String(describing: uid)
        if let range = desc.range(of: #"\{value = (\d+)\}"#, options: .regularExpression),
           let numRange = desc[range].range(of: #"\d+"#, options: .regularExpression) {
            return Int(desc[numRange])
        }
        // Fallback: CF$UID dict (older serialisers or manual construction)
        if let dict = uid as? [String: Any] {
            if let v = dict["CF$UID"] as? Int    { return v }
            if let v = dict["CF$UID"] as? UInt64 { return Int(v) }
        }
        return nil
    }
}
