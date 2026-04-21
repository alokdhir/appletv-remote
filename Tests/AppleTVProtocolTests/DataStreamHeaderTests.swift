import XCTest
@testable import AppleTVProtocol

/// Round-trip and wire-format tests for the 32-byte DataStreamMessage header
/// that frames every MRP payload inside the AirPlay data-stream tunnel.
///
/// Reference layout (all big-endian):
///   0..4    totalSize   u32
///   4..16   messageType 12 bytes ("sync\0…" or "rply\0…")
///  16..20   command     4 bytes  ("comm" or "\0\0\0\0")
///  20..28   seqno       u64
///  28..32   padding     u32 (0)
final class DataStreamHeaderTests: XCTestCase {

    // Pull the nested type via a typealias for readability.
    private typealias Header = MRPDataChannel.DataStreamHeader

    func testSyncHeaderWireFormat() {
        let payload = Data(repeating: 0xAB, count: 17)
        let totalSize = UInt32(Header.length + payload.count)   // 32 + 17 = 49

        let h = Header(
            totalSize: totalSize,
            messageType: (0x73, 0x79, 0x6e, 0x63, 0, 0, 0, 0, 0, 0, 0, 0), // "sync"
            command:     (0x63, 0x6f, 0x6d, 0x6d),                          // "comm"
            seqno: 0x0000_0001_2345_6789,
            padding: 0
        )
        let wire = h.encode()

        XCTAssertEqual(wire.count, Header.length)
        // totalSize
        XCTAssertEqual([UInt8](wire[0..<4]), [0, 0, 0, 49])
        // messageType "sync" + 8 nulls
        XCTAssertEqual([UInt8](wire[4..<16]),
                       [0x73,0x79,0x6e,0x63, 0,0,0,0, 0,0,0,0])
        // command "comm"
        XCTAssertEqual([UInt8](wire[16..<20]),
                       [0x63,0x6f,0x6d,0x6d])
        // seqno big-endian
        XCTAssertEqual([UInt8](wire[20..<28]),
                       [0,0,0,1, 0x23,0x45,0x67,0x89])
        // padding zero
        XCTAssertEqual([UInt8](wire[28..<32]), [0,0,0,0])
    }

    func testDecodeHeaderOnly() throws {
        let h = Header(
            totalSize: 32,
            messageType: (0x72, 0x70, 0x6c, 0x79, 0, 0, 0, 0, 0, 0, 0, 0), // "rply"
            command:     (0, 0, 0, 0),
            seqno: 42,
            padding: 0
        )
        let wire = h.encode()
        let decoded = try XCTUnwrap(Header.decode(wire))

        XCTAssertEqual(decoded.header.totalSize, 32)
        XCTAssertEqual(decoded.header.seqno, 42)
        XCTAssertEqual(decoded.payload.count, 0)
        XCTAssertEqual(decoded.header.messageType.0, 0x72) // 'r'
        XCTAssertEqual(decoded.header.messageType.3, 0x79) // 'y'
    }

    func testRoundTripWithPayload() throws {
        let payload = Data((0..<64).map { UInt8($0) })
        let h = Header(
            totalSize: UInt32(Header.length + payload.count),
            messageType: (0x73, 0x79, 0x6e, 0x63, 0, 0, 0, 0, 0, 0, 0, 0),
            command:     (0x63, 0x6f, 0x6d, 0x6d),
            seqno: 0xDEAD_BEEF_F00D_CAFE,
            padding: 0
        )
        var wire = h.encode()
        wire.append(payload)

        let decoded = try XCTUnwrap(Header.decode(wire))
        XCTAssertEqual(decoded.header.totalSize, UInt32(Header.length + payload.count))
        XCTAssertEqual(decoded.header.seqno, 0xDEAD_BEEF_F00D_CAFE)
        XCTAssertEqual(decoded.payload, payload)
    }

    func testDecodeRejectsShortBuffer() {
        // 31 bytes — one short of a valid header.
        let short = Data(repeating: 0, count: 31)
        XCTAssertNil(Header.decode(short))
    }

    func testDecodeRejectsTruncatedPayload() {
        // Claims totalSize = 48 (header + 16B payload) but only 40 bytes present.
        var wire = Data()
        wire.append(contentsOf: [0, 0, 0, 48])                          // totalSize
        wire.append(contentsOf: Array("sync".utf8) + [UInt8](repeating: 0, count: 8))
        wire.append(contentsOf: Array("comm".utf8))
        wire.append(contentsOf: [UInt8](repeating: 0, count: 8))        // seqno
        wire.append(contentsOf: [0, 0, 0, 0])                           // padding
        wire.append(contentsOf: [UInt8](repeating: 0xFF, count: 8))     // only 8 of 16 payload bytes

        XCTAssertEqual(wire.count, 40)
        XCTAssertNil(Header.decode(wire))
    }

    /// Regression guard for the Data-slicing class of bug we hit in AirPlayHTTP:
    /// decode must work on a `Data` whose `startIndex` is non-zero.
    func testDecodeOnSlicedBuffer() throws {
        let payload = Data(repeating: 0x5A, count: 8)
        let h = Header(
            totalSize: UInt32(Header.length + payload.count),
            messageType: (0x73, 0x79, 0x6e, 0x63, 0, 0, 0, 0, 0, 0, 0, 0),
            command:     (0x63, 0x6f, 0x6d, 0x6d),
            seqno: 7,
            padding: 0
        )
        var full = Data(repeating: 0xEE, count: 5)  // leading garbage
        full.append(h.encode())
        full.append(payload)

        // Slice WITHOUT copying — startIndex is 5, not 0.
        let sliced = full[5...]
        XCTAssertNotEqual(sliced.startIndex, 0)

        let decoded = try XCTUnwrap(Header.decode(sliced))
        XCTAssertEqual(decoded.header.seqno, 7)
        XCTAssertEqual(decoded.payload, payload)
    }
}
