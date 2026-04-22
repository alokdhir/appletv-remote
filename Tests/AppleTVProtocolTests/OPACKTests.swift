import XCTest
@testable import AppleTVProtocol

/// Tests for the OPACK encoder/decoder.
///
/// Wire-format references borrowed from pyatv's
/// tests/protocols/companion/test_opack.py and the OPACK spec comments in
/// Sources/AppleTVProtocol/OPACK.swift.
final class OPACKTests: XCTestCase {

    // MARK: - Small int tag (0x08–0x2F)

    func testSmallIntZero() {
        XCTAssertEqual(OPACK.pack(0), Data([0x08]))
    }

    func testSmallIntOne() {
        XCTAssertEqual(OPACK.pack(1), Data([0x09]))
    }

    func testSmallIntMax() {
        // 0x27 = 39 — largest value the small-int tag encodes inline.
        XCTAssertEqual(OPACK.pack(39), Data([0x2F]))
    }

    // MARK: - uint8 (0x30) — bug 79c: encoder should pick this for 0x28..0xFF

    func testUInt8BoundaryLower() {
        // 40 just above small-int range — previously went to uint32 (0x32)
        XCTAssertEqual(OPACK.pack(40), Data([0x30, 0x28]))
    }

    func testUInt8BoundaryUpper() {
        XCTAssertEqual(OPACK.pack(255), Data([0x30, 0xFF]))
    }

    // MARK: - uint16 (0x31) — little-endian

    func testUInt16BoundaryLower() {
        XCTAssertEqual(OPACK.pack(256), Data([0x31, 0x00, 0x01]))
    }

    func testUInt16BoundaryUpper() {
        XCTAssertEqual(OPACK.pack(65535), Data([0x31, 0xFF, 0xFF]))
    }

    // MARK: - uint32 (0x32) — little-endian

    func testUInt32BoundaryLower() {
        XCTAssertEqual(OPACK.pack(65536), Data([0x32, 0x00, 0x00, 0x01, 0x00]))
    }

    func testUInt32BoundaryUpper() {
        // 0xFFFFFFFF = 4_294_967_295
        XCTAssertEqual(OPACK.pack(4_294_967_295), Data([0x32, 0xFF, 0xFF, 0xFF, 0xFF]))
    }

    // MARK: - uint64 (0x33) — little-endian. Bug 79c: previously clamped to Int32.max

    func testUInt64ForValuesAboveUInt32Max() {
        let value = 0x1_0000_0000 // 2^32 — no longer fits uint32
        let bytes = OPACK.pack(value)
        XCTAssertEqual(bytes, Data([0x33, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00]))
    }

    // MARK: - Negative ints (0x36 int64 signed little-endian). Bug 79c: previously corrupted

    func testNegativeOneDoesNotBecomeLargePositive() {
        // Before fix: -1 → Int32(clamping: -1) = -1 → UInt32(bitPattern:) = 0xFFFFFFFF,
        // emitted as 0x32 0xFF 0xFF 0xFF 0xFF — which decodes as +4_294_967_295, not -1.
        // After fix: emit as 0x36 (int64 signed little-endian) with two's-complement 0xFF..FF.
        let bytes = OPACK.pack(-1)
        XCTAssertEqual(bytes, Data([0x36, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]))
    }

    func testNegativeIntMinRoundTrip() {
        // Int.min on 64-bit platforms = -2^63 = 0x8000_0000_0000_0000
        // Little-endian: 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x80
        let bytes = OPACK.pack(Int.min)
        XCTAssertEqual(bytes, Data([0x36, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80]))
    }

    // MARK: - Dict key ordering. Bug r2g: insertion order was non-deterministic

    func testDictKeysEncodedInSortedOrder() {
        // Two dicts with identical contents but different insertion orders must
        // produce identical OPACK bytes (keys sorted lexicographically).
        let d1: [String: Any] = ["b": 1, "a": 2, "c": 3]
        let d2: [String: Any] = ["c": 3, "a": 2, "b": 1]
        XCTAssertEqual(OPACK.pack(d1), OPACK.pack(d2))

        // And that sorted output is exactly what we expect.
        let expected = Data([
            0xE3,                // dict, 3 entries
            0x41, 0x61,          // "a"
            0x0A,                // small int 2
            0x41, 0x62,          // "b"
            0x09,                // small int 1
            0x41, 0x63,          // "c"
            0x0B,                // small int 3
        ])
        XCTAssertEqual(OPACK.pack(d1), expected)
    }

    // MARK: - Dict-count precondition. Bug r2g: silent truncation at 15

    func testDictAtLimit() {
        // 15 entries should encode cleanly.
        var d: [String: Any] = [:]
        for i in 0..<15 { d["k\(i)"] = i }
        let bytes = OPACK.pack(d)
        // First byte = 0xE0 + 15 = 0xEF.
        XCTAssertEqual(bytes.first, 0xEF)
    }

    // MARK: - Round-trip for values we now emit with 0x30/0x31/0x33/0x36

    func testRoundTripUInt8() {
        let packed = OPACK.pack(["k": 200])
        let decoded = OPACK.decodeDict(packed)
        XCTAssertEqual(decoded?["k"] as? Int, 200)
    }

    func testRoundTripUInt16() {
        let packed = OPACK.pack(["k": 40_000])
        let decoded = OPACK.decodeDict(packed)
        XCTAssertEqual(decoded?["k"] as? Int, 40_000)
    }

    func testRoundTripUInt32() {
        let packed = OPACK.pack(["k": 4_000_000_000])
        let decoded = OPACK.decodeDict(packed)
        XCTAssertEqual(decoded?["k"] as? Int, 4_000_000_000)
    }

    func testRoundTripUInt64() {
        let packed = OPACK.pack(["k": 0x1_0000_0000])
        let decoded = OPACK.decodeDict(packed)
        XCTAssertEqual(decoded?["k"] as? Int, 0x1_0000_0000)
    }

    func testRoundTripNegative() {
        let packed = OPACK.pack(["k": -42])
        let decoded = OPACK.decodeDict(packed)
        XCTAssertEqual(decoded?["k"] as? Int, -42)
    }
}
