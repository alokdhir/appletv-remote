import XCTest
@testable import AppleTVProtocol

/// Tests for BinaryPlistWriter and RTITextOperations.
///
/// BinaryPlistWriter tests verify structural correctness by round-tripping
/// through PropertyListSerialization (which can decode any valid bplist00).
///
/// RTITextOperations tests verify the produced payload decodes to the expected
/// keyed-archiver object graph — matching pyatv's rti_text_operations.py.
final class BinaryPlistWriterTests: XCTestCase {

    // MARK: - BinaryPlistWriter: addInt

    func testAddIntSmall() throws {
        var w = BinaryPlistWriter()
        let ref = w.addInt(42)
        let data = w.build(topObject: ref)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        XCTAssertEqual(plist as? Int, 42)
    }

    func testAddIntZero() throws {
        var w = BinaryPlistWriter()
        let ref = w.addInt(0)
        let data = w.build(topObject: ref)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        XCTAssertEqual(plist as? Int, 0)
    }

    func testAddInt256() throws {
        var w = BinaryPlistWriter()
        let ref = w.addInt(256)
        let data = w.build(topObject: ref)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        XCTAssertEqual(plist as? Int, 256)
    }

    func testAddInt100000() throws {
        var w = BinaryPlistWriter()
        let ref = w.addInt(100000)
        let data = w.build(topObject: ref)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        XCTAssertEqual(plist as? Int, 100000)
    }

    // MARK: - BinaryPlistWriter: addString

    func testAddASCIIString() throws {
        var w = BinaryPlistWriter()
        let ref = w.addString("hello")
        let data = w.build(topObject: ref)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        XCTAssertEqual(plist as? String, "hello")
    }

    func testAddUnicodeString() throws {
        var w = BinaryPlistWriter()
        let ref = w.addString("héllo 🌍")
        let data = w.build(topObject: ref)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        XCTAssertEqual(plist as? String, "héllo 🌍")
    }

    func testAddEmptyString() throws {
        var w = BinaryPlistWriter()
        let ref = w.addString("")
        let data = w.build(topObject: ref)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        XCTAssertEqual(plist as? String, "")
    }

    // MARK: - BinaryPlistWriter: addData

    func testAddData() throws {
        let bytes = Data([0xDE, 0xAD, 0xBE, 0xEF])
        var w = BinaryPlistWriter()
        let ref = w.addData(bytes)
        let data = w.build(topObject: ref)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        XCTAssertEqual(plist as? Data, bytes)
    }

    // MARK: - BinaryPlistWriter: addUID tag bytes

    /// UID(0) should produce the 0x80 tag (1-byte UID, value 0).
    func testAddUIDOneByte() {
        var w = BinaryPlistWriter()
        // Build a dict with a UID value and verify the raw tag in the output.
        // We use addUID then wrap in a dict so build() can use it as top object.
        let key = w.addString("k")
        let uid = w.addUID(5)
        let dict = w.addDict([(key, uid)])
        let data = w.build(topObject: dict)
        // Locate the UID bytes: tag 0x80 followed by value 0x05.
        let bytes = Array(data)
        XCTAssertTrue(bytes.contains(0x80), "Expected 0x80 (1-byte UID tag)")
        XCTAssertTrue(zip(bytes, bytes.dropFirst()).contains(where: { $0 == 0x80 && $1 == 0x05 }),
                      "Expected 0x80 0x05 sequence for UID(5)")
    }

    /// UID(256) should produce the 0x81 tag (2-byte UID).
    func testAddUIDTwoByte() {
        var w = BinaryPlistWriter()
        let key = w.addString("k")
        let uid = w.addUID(256)
        let dict = w.addDict([(key, uid)])
        let data = w.build(topObject: dict)
        let bytes = Array(data)
        XCTAssertTrue(bytes.contains(0x81), "Expected 0x81 (2-byte UID tag)")
    }

    /// UID(0x10000) should produce the 0x83 tag (4-byte UID).
    func testAddUIDFourByte() {
        var w = BinaryPlistWriter()
        let key = w.addString("k")
        let uid = w.addUID(0x10000)
        let dict = w.addDict([(key, uid)])
        let data = w.build(topObject: dict)
        let bytes = Array(data)
        XCTAssertTrue(bytes.contains(0x83), "Expected 0x83 (4-byte UID tag)")
    }

    // Note: addInt(-1) precondition failure is not tested here — precondition() crashes
    // the process and cannot be caught in XCTest without a subprocess harness.
    // The precondition is documented in the method signature.

    /// build() with more than 255 objects should use 2-byte refs and produce valid output.
    func testBuildOver255ObjectsUsesWideRefs() throws {
        var w = BinaryPlistWriter()
        var refs: [BinaryPlistWriter.ObjRef] = []
        for i in 0..<260 {
            refs.append(w.addInt(i))
        }
        let arr = w.addArray(refs)
        let data = w.build(topObject: arr)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [Int])
        XCTAssertEqual(plist.count, 260)
        XCTAssertEqual(plist[255], 255)
        XCTAssertEqual(plist[259], 259)
    }

    // MARK: - BinaryPlistWriter: addArray / addDict round-trip

    func testAddArray() throws {
        var w = BinaryPlistWriter()
        let a = w.addString("alpha")
        let b = w.addString("beta")
        let arr = w.addArray([a, b])
        let data = w.build(topObject: arr)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        XCTAssertEqual(plist as? [String], ["alpha", "beta"])
    }

    func testAddDict() throws {
        var w = BinaryPlistWriter()
        let k = w.addString("key")
        let v = w.addString("value")
        let dict = w.addDict([(k, v)])
        let data = w.build(topObject: dict)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        XCTAssertEqual((plist as? [String: String])?["key"], "value")
    }

    // MARK: - BinaryPlistWriter: build() header/trailer

    func testBuildHasBplist00Header() {
        var w = BinaryPlistWriter()
        let ref = w.addString("x")
        let data = w.build(topObject: ref)
        XCTAssertTrue(data.prefix(8) == Data("bplist00".utf8), "Missing bplist00 magic")
    }

    func testBuildOffsetTableCorrect() throws {
        // A valid bplist00 is accepted by PropertyListSerialization —
        // if the offset table is wrong it will throw.
        var w = BinaryPlistWriter()
        let s1 = w.addString("one")
        let s2 = w.addString("two")
        let s3 = w.addInt(3)
        let arr = w.addArray([s1, s2, s3])
        let data = w.build(topObject: arr)
        XCTAssertNoThrow(try PropertyListSerialization.propertyList(from: data, format: nil))
    }
}

// MARK: - RTITextOperations tests

final class RTITextOperationsTests: XCTestCase {

    /// Fixed 16-byte session UUID used in all fixture tests.
    private let fixedUUID = Data([
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10,
    ])

    // MARK: - inputPayload structural tests

    func testInputPayloadIsValidPlist() {
        let payload = RTITextOperations.inputPayload(sessionUUID: fixedUUID, text: "hello")
        XCTAssertNoThrow(try PropertyListSerialization.propertyList(from: payload, format: nil))
    }

    func testInputPayloadHasCorrectArchiver() throws {
        let payload = RTITextOperations.inputPayload(sessionUUID: fixedUUID, text: "hello")
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: payload, format: nil) as? [String: Any])
        XCTAssertEqual(plist["$archiver"] as? String, "RTIKeyedArchiver")
        XCTAssertEqual(plist["$version"] as? Int, 100000)
    }

    func testInputPayloadObjectsCount() throws {
        let payload = RTITextOperations.inputPayload(sessionUUID: fixedUUID, text: "hello")
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: payload, format: nil) as? [String: Any])
        let objects = try XCTUnwrap(plist["$objects"] as? [Any])
        XCTAssertEqual(objects.count, 8, "$objects must have exactly 8 entries")
    }

    func testInputPayloadObjectsNullFirst() throws {
        let payload = RTITextOperations.inputPayload(sessionUUID: fixedUUID, text: "hello")
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: payload, format: nil) as? [String: Any])
        let objects = try XCTUnwrap(plist["$objects"] as? [Any])
        XCTAssertEqual(objects[0] as? String, "$null", "$objects[0] must be '$null'")
    }

    func testInputPayloadTextAtIndex3() throws {
        let text = "test string"
        let payload = RTITextOperations.inputPayload(sessionUUID: fixedUUID, text: text)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: payload, format: nil) as? [String: Any])
        let objects = try XCTUnwrap(plist["$objects"] as? [Any])
        XCTAssertEqual(objects[3] as? String, text, "$objects[3] must be the input text")
    }

    func testInputPayloadUUIDAtIndex5() throws {
        let payload = RTITextOperations.inputPayload(sessionUUID: fixedUUID, text: "x")
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: payload, format: nil) as? [String: Any])
        let objects = try XCTUnwrap(plist["$objects"] as? [Any])
        let nsuuidDict = try XCTUnwrap(objects[5] as? [String: Any])
        XCTAssertEqual(nsuuidDict["NS.uuidbytes"] as? Data, fixedUUID)
    }

    func testInputPayloadClassNamesPresent() throws {
        let payload = RTITextOperations.inputPayload(sessionUUID: fixedUUID, text: "x")
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: payload, format: nil) as? [String: Any])
        let objects = try XCTUnwrap(plist["$objects"] as? [Any])
        let tikbClass = try XCTUnwrap(objects[4] as? [String: Any])
        let nsuuidClass = try XCTUnwrap(objects[6] as? [String: Any])
        let rtiClass = try XCTUnwrap(objects[7] as? [String: Any])
        XCTAssertEqual(tikbClass["$classname"] as? String, "TIKeyboardOutput")
        XCTAssertEqual(nsuuidClass["$classname"] as? String, "NSUUID")
        XCTAssertEqual(rtiClass["$classname"] as? String, "RTITextOperations")
    }

    func testInputPayloadTopPointsToIndex1() throws {
        let payload = RTITextOperations.inputPayload(sessionUUID: fixedUUID, text: "x")
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: payload, format: nil) as? [String: Any])
        let top = try XCTUnwrap(plist["$top"] as? [String: Any])
        let uid = try XCTUnwrap(top["textOperations"])
        XCTAssertEqual(uidIndex(uid), 1, "$top.textOperations must point to $objects[1]")
    }

    // MARK: - clearPayload structural tests

    func testClearPayloadIsValidPlist() {
        let payload = RTITextOperations.clearPayload(sessionUUID: fixedUUID)
        XCTAssertNoThrow(try PropertyListSerialization.propertyList(from: payload, format: nil))
    }

    func testClearPayloadObjectsCount() throws {
        let payload = RTITextOperations.clearPayload(sessionUUID: fixedUUID)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: payload, format: nil) as? [String: Any])
        let objects = try XCTUnwrap(plist["$objects"] as? [Any])
        XCTAssertEqual(objects.count, 8)
    }

    func testClearPayloadEmptyStringAtIndex4() throws {
        let payload = RTITextOperations.clearPayload(sessionUUID: fixedUUID)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: payload, format: nil) as? [String: Any])
        let objects = try XCTUnwrap(plist["$objects"] as? [Any])
        XCTAssertEqual(objects[4] as? String, "", "$objects[4] must be empty string (textToAssert)")
    }

    func testClearPayloadUUIDAtIndex5() throws {
        let payload = RTITextOperations.clearPayload(sessionUUID: fixedUUID)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: payload, format: nil) as? [String: Any])
        let objects = try XCTUnwrap(plist["$objects"] as? [Any])
        let nsuuidDict = try XCTUnwrap(objects[5] as? [String: Any])
        XCTAssertEqual(nsuuidDict["NS.uuidbytes"] as? Data, fixedUUID)
    }

    // MARK: - extractSessionUUID tests

    func testExtractSessionUUIDFromNSUUIDDict() throws {
        // Build a minimal _tiD plist that wraps the UUID in an NSUUID dict
        // (the fallback path in extractSessionUUID).
        let uuidData = Data([
            0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11, 0x22,
            0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0x00,
        ])

        // Build a valid NSKeyedArchiver plist using PropertyListSerialization
        // so we get a proper UID type in $top.
        let plistDict: [String: Any] = [
            "$version": 100000,
            "$archiver": "NSKeyedArchiver",
            "$top": ["sessionUUID": ["CF$UID": 1]],
            "$objects": [
                "$null",
                ["NS.uuidbytes": uuidData, "$class": ["CF$UID": 2]],
                ["$classname": "NSUUID", "$classes": ["NSUUID", "NSObject"]],
            ],
        ]
        let tiD = try PropertyListSerialization.data(fromPropertyList: plistDict,
                                                      format: .binary,
                                                      options: 0)
        let extracted = RTITextOperations.extractSessionUUID(from: tiD)
        XCTAssertEqual(extracted, uuidData)
    }

    func testExtractSessionUUIDFromRawData() throws {
        // Build a plist where $objects[1] is a raw 16-byte Data (tvOS fast path).
        let uuidData = Data(repeating: 0xAB, count: 16)
        let plistDict: [String: Any] = [
            "$version": 100000,
            "$archiver": "NSKeyedArchiver",
            "$top": ["sessionUUID": ["CF$UID": 1]],
            "$objects": ["$null", uuidData],
        ]
        let tiD = try PropertyListSerialization.data(fromPropertyList: plistDict,
                                                      format: .binary,
                                                      options: 0)
        let extracted = RTITextOperations.extractSessionUUID(from: tiD)
        XCTAssertEqual(extracted, uuidData)
    }

    func testExtractSessionUUIDMissingKeyReturnsNil() throws {
        let plistDict: [String: Any] = [
            "$version": 100000,
            "$archiver": "NSKeyedArchiver",
            "$top": ["wrongKey": ["CF$UID": 1]],
            "$objects": ["$null", Data(repeating: 0, count: 16)],
        ]
        let tiD = try PropertyListSerialization.data(fromPropertyList: plistDict,
                                                      format: .binary,
                                                      options: 0)
        XCTAssertNil(RTITextOperations.extractSessionUUID(from: tiD))
    }

    // MARK: - Round-trip: inputPayload UUID survives encode/decode

    func testInputPayloadRoundTripUUID() throws {
        let payload = RTITextOperations.inputPayload(sessionUUID: fixedUUID, text: "roundtrip")
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: payload, format: nil) as? [String: Any])
        let objects = try XCTUnwrap(plist["$objects"] as? [Any])
        let nsuuidDict = try XCTUnwrap(objects[5] as? [String: Any])
        XCTAssertEqual(nsuuidDict["NS.uuidbytes"] as? Data, fixedUUID,
                       "UUID bytes must survive encode/decode")
    }

    // MARK: - Helpers

    /// Mirror of RTITextOperations.uidIndex for use in tests.
    private func uidIndex(_ uid: Any) -> Int? {
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
