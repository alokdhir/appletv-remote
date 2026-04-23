import XCTest
@testable import AppleTVProtocol

final class CompanionFrameTests: XCTestCase {

    // MARK: - Encode

    func testEncodeRoundTrip() {
        let payload = Data([0x01, 0x02, 0x03])
        let frame = CompanionFrame(type: .eOPACK, payload: payload)
        let encoded = frame.encoded
        // 1-byte type + 3-byte big-endian length + payload
        XCTAssertEqual(encoded, Data([0x08, 0x00, 0x00, 0x03, 0x01, 0x02, 0x03]))
    }

    func testEncodeEmptyPayload() {
        let frame = CompanionFrame(type: .psStart, payload: Data())
        XCTAssertEqual(frame.encoded, Data([0x03, 0x00, 0x00, 0x00]))
    }

    func testEncodeLargePayloadLength() {
        let payload = Data(repeating: 0xAB, count: 0x010203)
        let frame = CompanionFrame(type: .pvNext, payload: payload)
        let encoded = frame.encoded
        XCTAssertEqual(encoded[0], 0x06)
        XCTAssertEqual(encoded[1], 0x01)
        XCTAssertEqual(encoded[2], 0x02)
        XCTAssertEqual(encoded[3], 0x03)
        XCTAssertEqual(encoded.count, 4 + 0x010203)
    }

    // MARK: - Decode — normal

    func testDecodeKnownFrame() {
        var buf = Data([0x08, 0x00, 0x00, 0x03, 0xAA, 0xBB, 0xCC])
        let frame = CompanionFrame.read(from: &buf)
        XCTAssertNotNil(frame)
        XCTAssertEqual(frame?.type, .eOPACK)
        XCTAssertEqual(frame?.payload, Data([0xAA, 0xBB, 0xCC]))
        XCTAssertTrue(buf.isEmpty)
    }

    func testDecodeConsumesOnlyOneFrame() {
        var buf = Data([
            0x04, 0x00, 0x00, 0x01, 0xFF,   // psNext, 1 byte
            0x06, 0x00, 0x00, 0x01, 0xEE,   // pvNext, 1 byte
        ])
        let f1 = CompanionFrame.read(from: &buf)
        XCTAssertEqual(f1?.type, .psNext)
        XCTAssertEqual(f1?.payload, Data([0xFF]))
        XCTAssertEqual(buf.count, 5)

        let f2 = CompanionFrame.read(from: &buf)
        XCTAssertEqual(f2?.type, .pvNext)
        XCTAssertEqual(f2?.payload, Data([0xEE]))
        XCTAssertTrue(buf.isEmpty)
    }

    // MARK: - Decode — partial buffer

    func testDecodeReturnsNilOnTruncatedHeader() {
        var buf = Data([0x08, 0x00, 0x00])   // only 3 bytes, need 4
        XCTAssertNil(CompanionFrame.read(from: &buf))
        XCTAssertEqual(buf.count, 3)         // buffer unchanged
    }

    func testDecodeReturnsNilOnTruncatedPayload() {
        var buf = Data([0x08, 0x00, 0x00, 0x05, 0x01, 0x02])  // claims 5 bytes, only 2
        XCTAssertNil(CompanionFrame.read(from: &buf))
        XCTAssertEqual(buf.count, 6)         // buffer unchanged
    }

    func testDecodeEmptyBufferReturnsNil() {
        var buf = Data()
        XCTAssertNil(CompanionFrame.read(from: &buf))
    }

    // MARK: - Decode — unknown type byte

    func testDecodeUnknownTypeReturnsNilAndConsumesBytes() {
        var buf = Data([0xFF, 0x00, 0x00, 0x02, 0x01, 0x02])  // 0xFF is not a known FrameType
        let frame = CompanionFrame.read(from: &buf)
        XCTAssertNil(frame)
        // Buffer should be consumed so we don't stall on the same bad frame
        XCTAssertTrue(buf.isEmpty)
    }

    // MARK: - Round-trip all frame types

    func testRoundTripAllFrameTypes() {
        let types: [CompanionFrame.FrameType] = [.psStart, .psNext, .pvStart, .pvNext, .eOPACK]
        for t in types {
            let payload = Data([0xDE, 0xAD])
            var buf = CompanionFrame(type: t, payload: payload).encoded
            let decoded = CompanionFrame.read(from: &buf)
            XCTAssertEqual(decoded?.type, t, "round-trip failed for \(t)")
            XCTAssertEqual(decoded?.payload, payload)
        }
    }
}
