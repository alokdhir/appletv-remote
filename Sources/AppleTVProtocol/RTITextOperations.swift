import Foundation

/// Builds and parses the RTI (Remote Text Input) binary plist payloads
/// used in Companion `_tiC` events.
///
/// The payload is an RTIKeyedArchiver-encoded binary plist containing an
/// `RTITextOperations` object — matching pyatv's
/// `plist_payloads/rti_text_operations.py` exactly.
///
/// We build the binary plist by hand using `BinaryPlistWriter` because
/// `PropertyListSerialization` serialises `["CF$UID": N]` dicts as regular
/// dictionaries rather than the opaque `0x8N` UID type that RTIKeyedArchiver
/// requires for object cross-references.
///
/// Key rule: in an NSKeyedArchiver archive every value inside an instance dict
/// is a UID reference into the `$objects` array — even plain strings.
/// The `$objects` array holds the actual objects; UID(N) = `$objects[N]`.
public enum RTITextOperations {

    // MARK: - Encode

    /// Build a payload that inserts `text` at the current cursor position.
    ///
    /// `$objects` layout (matches pyatv rti_text_operations.py exactly):
    ///   [0]  "$null"
    ///   [1]  RTITextOperations instance  { keyboardOutput:UID(2), targetSessionUUID:UID(5), $class:UID(7) }
    ///   [2]  TIKeyboardOutput instance   { insertionText:UID(3),  $class:UID(4) }
    ///   [3]  text string
    ///   [4]  TIKeyboardOutput class dict { $classname, $classes }
    ///   [5]  NSUUID instance dict        { NS.uuidbytes:<Data>,   $class:UID(6) }
    ///   [6]  NSUUID class dict           { $classname, $classes }
    ///   [7]  RTITextOperations class dict { $classname, $classes }
    public static func inputPayload(sessionUUID: Data, text: String) -> Data {
        // We build a single flat BinaryPlistWriter. Every object gets a bplist
        // index. The $objects array references each element by its bplist ObjRef.
        // Instance dicts use UID(N) where N is the position of the target in
        // the $objects array — so we must ensure the $objects array is built
        // in the exact order declared above.
        //
        // The trick: build ALL leaf objects first (in any order), then build the
        // instance dicts using UID(N) with the N values we know from the layout,
        // then assemble the $objects array with elements in the exact right order.

        var w = BinaryPlistWriter()

        // ── String keys (shared across dicts) ─────────────────────────────────
        let skClass       = w.addString("$class")
        let skClassname   = w.addString("$classname")
        let skClasses     = w.addString("$classes")
        let skKbOut       = w.addString("keyboardOutput")
        let skTargetUUID  = w.addString("targetSessionUUID")
        let skInsertText  = w.addString("insertionText")
        let skNSUUIDbytes = w.addString("NS.uuidbytes")

        // ── $objects[3]: text string ───────────────────────────────────────────
        let obj3Text     = w.addString(text)

        // ── $objects[4]: TIKeyboardOutput class dict ───────────────────────────
        let sTIKBName    = w.addString("TIKeyboardOutput")
        let sNSObject    = w.addString("NSObject")
        let aTIKBClasses = w.addArray([sTIKBName, sNSObject])
        let obj4TIKBCls  = w.addDict([(skClassname, sTIKBName), (skClasses, aTIKBClasses)])

        // ── $objects[5]: NSUUID instance dict ─────────────────────────────────
        // NS.uuidbytes value is data — in NSKeyedArchiver, raw Data values ARE
        // stored inline as the value (not as a UID ref). So we embed the data
        // directly, not via UID. (This is how pyatv does it too.)
        let oUUIDData      = w.addData(sessionUUID)
        let sNSUUID        = w.addString("NSUUID")
        let aNSUUIDClasses = w.addArray([sNSUUID, sNSObject])
        let obj6NSUUIDCls  = w.addDict([(skClassname, sNSUUID), (skClasses, aNSUUIDClasses)])
        // obj5 references obj6 via UID(6):
        let obj5NSUUIDInst = w.addDict([
            (skNSUUIDbytes, oUUIDData),
            (skClass,       w.addUID(6)),  // UID(6) = $objects[6]
        ])

        // ── $objects[6] is already built above (obj6NSUUIDCls)

        // ── $objects[7]: RTITextOperations class dict ──────────────────────────
        let sRTIName    = w.addString("RTITextOperations")
        let aRTIClasses = w.addArray([sRTIName, sNSObject])
        let obj7RTICls  = w.addDict([(skClassname, sRTIName), (skClasses, aRTIClasses)])

        // ── $objects[2]: TIKeyboardOutput instance dict ────────────────────────
        // insertionText → UID(3) = $objects[3] = text string
        // $class        → UID(4) = $objects[4] = TIKeyboardOutput class dict
        let obj2TIKBInst = w.addDict([
            (skInsertText, w.addUID(3)),  // UID(3)
            (skClass,      w.addUID(4)),  // UID(4)
        ])

        // ── $objects[1]: RTITextOperations instance dict ───────────────────────
        // keyboardOutput    → UID(2) = $objects[2] = TIKeyboardOutput instance
        // targetSessionUUID → UID(5) = $objects[5] = NSUUID instance
        // $class            → UID(7) = $objects[7] = RTITextOperations class
        let obj1RTIInst = w.addDict([
            (skKbOut,      w.addUID(2)),  // UID(2)
            (skTargetUUID, w.addUID(5)),  // UID(5)
            (skClass,      w.addUID(7)),  // UID(7)
        ])

        // ── $objects[0]: "$null" ───────────────────────────────────────────────
        let obj0Null = w.addNull()

        // ── $objects array in exact order ──────────────────────────────────────
        let objsArray = w.addArray([
            obj0Null,       // [0]
            obj1RTIInst,    // [1]
            obj2TIKBInst,   // [2]
            obj3Text,       // [3]
            obj4TIKBCls,    // [4]
            obj5NSUUIDInst, // [5]
            obj6NSUUIDCls,  // [6]
            obj7RTICls,     // [7]
        ])

        // ── Outer keyed-archiver wrapper ──────────────────────────────────────
        let skVersion  = w.addString("$version")
        let skArchiver = w.addString("$archiver")
        let skTop      = w.addString("$top")
        let skObjects  = w.addString("$objects")
        let svArchiver = w.addString("RTIKeyedArchiver")
        let skTextOps  = w.addString("textOperations")
        let svVersion  = w.addInt(100000)

        // $top.textOperations → UID(1) = $objects[1] = RTITextOperations instance
        let topDict  = w.addDict([(skTextOps, w.addUID(1))])
        let rootDict = w.addDict([
            (skVersion,  svVersion),
            (skArchiver, svArchiver),
            (skTop,      topDict),
            (skObjects,  objsArray),
        ])

        return w.build(topObject: rootDict)
    }

    /// Build a payload that clears the current field content.
    ///
    /// `$objects` layout:
    ///   [0]  "$null"
    ///   [1]  RTITextOperations instance  { keyboardOutput:UID(2), targetSessionUUID:UID(5), textToAssert:UID(4), $class:UID(7) }
    ///   [2]  TIKeyboardOutput instance   { $class:UID(3) }
    ///   [3]  TIKeyboardOutput class dict
    ///   [4]  "" (empty string — textToAssert)
    ///   [5]  NSUUID instance dict
    ///   [6]  NSUUID class dict
    ///   [7]  RTITextOperations class dict
    public static func clearPayload(sessionUUID: Data) -> Data {
        var w = BinaryPlistWriter()

        let skClass       = w.addString("$class")
        let skClassname   = w.addString("$classname")
        let skClasses     = w.addString("$classes")
        let skKbOut       = w.addString("keyboardOutput")
        let skTargetUUID  = w.addString("targetSessionUUID")
        let skTextAssert  = w.addString("textToAssert")
        let skNSUUIDbytes = w.addString("NS.uuidbytes")

        // ── $objects[4]: empty string ──────────────────────────────────────────
        let obj4Empty    = w.addString("")

        // ── $objects[3]: TIKeyboardOutput class dict ───────────────────────────
        let sTIKBName    = w.addString("TIKeyboardOutput")
        let sNSObject    = w.addString("NSObject")
        let aTIKBClasses = w.addArray([sTIKBName, sNSObject])
        let obj3TIKBCls  = w.addDict([(skClassname, sTIKBName), (skClasses, aTIKBClasses)])

        // ── $objects[5]: NSUUID instance dict ─────────────────────────────────
        let oUUIDData      = w.addData(sessionUUID)
        let sNSUUID        = w.addString("NSUUID")
        let aNSUUIDClasses = w.addArray([sNSUUID, sNSObject])
        let obj6NSUUIDCls  = w.addDict([(skClassname, sNSUUID), (skClasses, aNSUUIDClasses)])
        let obj5NSUUIDInst = w.addDict([
            (skNSUUIDbytes, oUUIDData),
            (skClass,       w.addUID(6)),  // UID(6) = $objects[6]
        ])

        // ── $objects[7]: RTITextOperations class dict ──────────────────────────
        let sRTIName    = w.addString("RTITextOperations")
        let aRTIClasses = w.addArray([sRTIName, sNSObject])
        let obj7RTICls  = w.addDict([(skClassname, sRTIName), (skClasses, aRTIClasses)])

        // ── $objects[2]: TIKeyboardOutput instance (empty) ────────────────────
        let obj2TIKBInst = w.addDict([
            (skClass, w.addUID(3)),  // UID(3) = $objects[3]
        ])

        // ── $objects[1]: RTITextOperations instance ────────────────────────────
        let obj1RTIInst = w.addDict([
            (skKbOut,      w.addUID(2)),  // UID(2)
            (skTargetUUID, w.addUID(5)),  // UID(5)
            (skTextAssert, w.addUID(4)),  // UID(4) = empty string
            (skClass,      w.addUID(7)),  // UID(7)
        ])

        let obj0Null = w.addNull()

        let objsArray = w.addArray([
            obj0Null,       // [0]
            obj1RTIInst,    // [1]
            obj2TIKBInst,   // [2]
            obj3TIKBCls,    // [3]
            obj4Empty,      // [4]
            obj5NSUUIDInst, // [5]
            obj6NSUUIDCls,  // [6]
            obj7RTICls,     // [7]
        ])

        let skVersion  = w.addString("$version")
        let skArchiver = w.addString("$archiver")
        let skTop      = w.addString("$top")
        let skObjects  = w.addString("$objects")
        let svArchiver = w.addString("RTIKeyedArchiver")
        let skTextOps  = w.addString("textOperations")
        let svVersion  = w.addInt(100000)

        let topDict  = w.addDict([(skTextOps, w.addUID(1))])
        let rootDict = w.addDict([
            (skVersion,  svVersion),
            (skArchiver, svArchiver),
            (skTop,      topDict),
            (skObjects,  objsArray),
        ])

        return w.build(topObject: rootDict)
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

    /// Extract the integer index from a UID.
    /// PropertyListSerialization returns CFKeyedArchiverUID as an opaque __NSCFType
    /// whose description is "<CFKeyedArchiverUID 0x...>{value = N}".
    private static func uidIndex(_ uid: Any) -> Int? {
        let desc = String(describing: uid)
        if let range = desc.range(of: #"\{value = (\d+)\}"#, options: .regularExpression),
           let numRange = desc[range].range(of: #"\d+"#, options: .regularExpression) {
            return Int(desc[numRange])
        }
        if let dict = uid as? [String: Any] {
            if let v = dict["CF$UID"] as? Int    { return v }
            if let v = dict["CF$UID"] as? UInt64 { return Int(v) }
        }
        return nil
    }
}
