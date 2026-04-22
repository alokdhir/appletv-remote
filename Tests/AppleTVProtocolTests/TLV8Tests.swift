import XCTest
@testable import AppleTVProtocol

/// Tests for TLV8 encode/decode, >255-byte fragment reassembly, and subscript lookup.
///
/// Format: tag (1 byte) + length (1 byte, 0–255) + data.
/// Values >255 bytes are split into consecutive fragments with the same tag
/// and reassembled by the decoder.
final class TLV8Tests: XCTestCase {

    // MARK: - Encode

    func testEncodeSingleByteValue() {
        var tlv = TLV8()
        tlv.append(.state, byte: 0x01)
        XCTAssertEqual(tlv.encode(), Data([0x06, 0x01, 0x01]))
    }

    func testEncodeMultipleEntries() {
        var tlv = TLV8()
        tlv.append(.state, byte: 0x01)
        tlv.append(.method, byte: 0x00)
        XCTAssertEqual(tlv.encode(), Data([0x06, 0x01, 0x01, 0x00, 0x01, 0x00]))
    }

    func testEncodeEmptyValue() {
        var tlv = TLV8()
        tlv.append(.separator, Data())
        XCTAssertEqual(tlv.encode(), Data([0xFF, 0x00]))
    }

    func testEncodeExactly255ByteValue() {
        let payload = Data(repeating: 0xAB, count: 255)
        var tlv = TLV8()
        tlv.append(.publicKey, payload)
        let encoded = tlv.encode()
        // Single fragment: tag + 0xFF + 255 bytes
        XCTAssertEqual(encoded.count, 257)
        XCTAssertEqual(encoded[0], TLV8.Tag.publicKey.rawValue)
        XCTAssertEqual(encoded[1], 255)
        XCTAssertEqual(encoded.suffix(255), payload)
    }

    func testEncodeFragmentsValueOver255Bytes() {
        let payload = Data(repeating: 0xCC, count: 300)
        var tlv = TLV8()
        tlv.append(.publicKey, payload)
        let encoded = tlv.encode()
        // First fragment: tag + 0xFF + 255 bytes = 257 bytes
        // Second fragment: tag + 0x2D + 45 bytes = 47 bytes
        XCTAssertEqual(encoded.count, 257 + 47)
        XCTAssertEqual(encoded[0], TLV8.Tag.publicKey.rawValue)
        XCTAssertEqual(encoded[1], 255)
        XCTAssertEqual(encoded[257], TLV8.Tag.publicKey.rawValue)
        XCTAssertEqual(encoded[258], 45)
    }

    func testEncodeFragmentsExactMultipleOf255() {
        let payload = Data(repeating: 0xDD, count: 510)
        var tlv = TLV8()
        tlv.append(.publicKey, payload)
        let encoded = tlv.encode()
        // Two full fragments: (1+1+255) * 2 = 514 bytes
        XCTAssertEqual(encoded.count, 514)
    }

    // MARK: - Decode

    func testDecodeSingleByteValue() {
        let data = Data([0x06, 0x01, 0x01])
        let tlv = TLV8.decode(data)
        XCTAssertEqual(tlv[.state], Data([0x01]))
    }

    func testDecodeMultipleEntries() {
        let data = Data([0x06, 0x01, 0x02, 0x00, 0x01, 0x03])
        let tlv = TLV8.decode(data)
        XCTAssertEqual(tlv[.state], Data([0x02]))
        XCTAssertEqual(tlv[.method], Data([0x03]))
    }

    func testDecodeEmptyValue() {
        let data = Data([0xFF, 0x00])
        let tlv = TLV8.decode(data)
        XCTAssertEqual(tlv[.separator], Data())
    }

    func testDecodeEmptyData() {
        let tlv = TLV8.decode(Data())
        XCTAssertTrue(tlv.allEntries.isEmpty)
    }

    func testDecodeTruncatedData() {
        // Only tag byte, no length — decoder should stop gracefully
        let data = Data([0x06])
        let tlv = TLV8.decode(data)
        XCTAssertTrue(tlv.allEntries.isEmpty)
    }

    func testDecodeReassemblesFragmentedValue() {
        // Two consecutive fragments with tag 0x03 (publicKey)
        let fragment1 = Data(repeating: 0xAA, count: 255)
        let fragment2 = Data(repeating: 0xBB, count: 45)
        var data = Data()
        data.append(0x03); data.append(255); data.append(contentsOf: fragment1)
        data.append(0x03); data.append(45);  data.append(contentsOf: fragment2)

        let tlv = TLV8.decode(data)
        let reassembled = tlv[.publicKey]
        XCTAssertNotNil(reassembled)
        XCTAssertEqual(reassembled?.count, 300)
        XCTAssertEqual(reassembled?.prefix(255), fragment1)
        XCTAssertEqual(reassembled?.suffix(45), fragment2)
    }

    func testDecodeReassemblesThreeFragments() {
        let chunk = Data(repeating: 0xFF, count: 255)
        var data = Data()
        for _ in 0..<3 {
            data.append(0x03); data.append(255); data.append(contentsOf: chunk)
        }
        let tlv = TLV8.decode(data)
        XCTAssertEqual(tlv[.publicKey]?.count, 765)
    }

    func testDecodeDoesNotMergeNonConsecutiveFragments() {
        // tag A, tag B, tag A — the two A entries should NOT be merged
        var data = Data()
        data.append(0x03); data.append(2); data.append(contentsOf: [0x01, 0x02])
        data.append(0x06); data.append(1); data.append(0x01)
        data.append(0x03); data.append(2); data.append(contentsOf: [0x03, 0x04])

        let tlv = TLV8.decode(data)
        // First publicKey entry wins for subscript lookup
        XCTAssertEqual(tlv[.publicKey], Data([0x01, 0x02]))
        // allEntries contains both publicKey entries
        let pkEntries = tlv.allEntries.filter { $0.0 == TLV8.Tag.publicKey.rawValue }
        XCTAssertEqual(pkEntries.count, 2)
    }

    // MARK: - Round-trip

    func testRoundTripSingleEntry() {
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        var tlv = TLV8()
        tlv.append(.encryptedData, payload)
        let decoded = TLV8.decode(tlv.encode())
        XCTAssertEqual(decoded[.encryptedData], payload)
    }

    func testRoundTripMultipleEntries() {
        var tlv = TLV8()
        tlv.append(.state,      byte: 0x02)
        tlv.append(.identifier, Data([0x41, 0x42, 0x43]))
        tlv.append(.salt,       Data(repeating: 0x5A, count: 16))

        let decoded = TLV8.decode(tlv.encode())
        XCTAssertEqual(decoded[.state],      Data([0x02]))
        XCTAssertEqual(decoded[.identifier], Data([0x41, 0x42, 0x43]))
        XCTAssertEqual(decoded[.salt],       Data(repeating: 0x5A, count: 16))
    }

    func testRoundTripLargeFragmentedValue() {
        let payload = Data((0..<600).map { UInt8($0 % 256) })
        var tlv = TLV8()
        tlv.append(.certificate, payload)
        let decoded = TLV8.decode(tlv.encode())
        XCTAssertEqual(decoded[.certificate], payload)
    }

    // MARK: - Subscript lookup

    func testSubscriptReturnsNilForMissingTag() {
        let tlv = TLV8.decode(Data([0x06, 0x01, 0x01]))
        XCTAssertNil(tlv[.publicKey])
    }

    func testSubscriptReturnsReassembledValueForConsecutiveSameTagEntries() {
        // Consecutive entries with the same tag are reassembled by the decoder.
        var data = Data()
        data.append(0x06); data.append(1); data.append(0x01)
        data.append(0x06); data.append(1); data.append(0x02)
        let tlv = TLV8.decode(data)
        XCTAssertEqual(tlv[.state], Data([0x01, 0x02]))
    }
}
