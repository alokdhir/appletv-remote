import XCTest
@testable import AppleTVProtocol

final class MRPDecoderTests: XCTestCase {

    // MARK: - Helpers

    /// Encode a protobuf varint.
    private func varint(_ v: UInt64) -> [UInt8] {
        var n = v; var out: [UInt8] = []
        repeat {
            var b = UInt8(n & 0x7F); n >>= 7
            if n != 0 { b |= 0x80 }
            out.append(b)
        } while n != 0
        return out
    }

    /// Encode a length-delimited field (wire type 2).
    private func field(_ number: Int, bytes: [UInt8]) -> [UInt8] {
        let tag = UInt64((number << 3) | 2)
        return varint(tag) + varint(UInt64(bytes.count)) + bytes
    }

    /// Encode a varint field (wire type 0).
    private func field(_ number: Int, varint v: UInt64) -> [UInt8] {
        let tag = UInt64((number << 3) | 0)
        return varint(tag) + varint(v)
    }

    /// Encode a 64-bit little-endian double field (wire type 1).
    private func field(_ number: Int, double v: Double) -> [UInt8] {
        let tag = UInt64((number << 3) | 1)
        var bits = v.bitPattern
        var bytes = [UInt8](repeating: 0, count: 8)
        for i in 0..<8 { bytes[i] = UInt8(bits & 0xFF); bits >>= 8 }
        return varint(tag) + bytes
    }

    /// Build a full SET_STATE_MESSAGE protobuf with the given fields.
    private func makeSetState(playbackState: UInt64? = nil,
                              timestamp: Double? = nil,
                              title: String? = nil,
                              artist: String? = nil,
                              album: String? = nil) -> Data {
        // ContentItemMetadata (field 2 of ContentItem)
        var meta: [UInt8] = []
        if let t = title  { meta += field(1, bytes: Array(t.utf8)) }
        if let al = album  { meta += field(6, bytes: Array(al.utf8)) }
        if let ar = artist { meta += field(7, bytes: Array(ar.utf8)) }

        // ContentItem (field 2 of PlaybackQueue)
        let ci: [UInt8] = meta.isEmpty ? [] : field(2, bytes: meta)

        // PlaybackQueue (field 3 of SetStateMessage)
        let pq: [UInt8] = ci.isEmpty ? [] : field(2, bytes: ci)

        // SetStateMessage
        var ssm: [UInt8] = []
        if let s = playbackState { ssm += field(6, varint: s) }
        if let ts = timestamp    { ssm += field(11, double: ts) }
        if !pq.isEmpty           { ssm += field(3, bytes: pq) }

        // ProtocolMessage: msgType=4 (field 1), SetStateMessage (field 9)
        var msg: [UInt8] = field(1, varint: 4)
        msg += field(9, bytes: ssm)
        return Data(msg)
    }

    // MARK: - messageType

    func testMessageTypeReturnsCorrectValue() {
        let data = makeSetState(playbackState: 1)
        XCTAssertEqual(MRPDecoder.messageType(from: data), 4)
    }

    func testMessageTypeReturnsNilForEmpty() {
        XCTAssertNil(MRPDecoder.messageType(from: Data()))
    }

    // MARK: - decodeNowPlaying — unknown message type

    func testUnknownMessageTypeReturnsNil() {
        // msgType=99, no extension field
        let data = Data(field(1, varint: 99))
        XCTAssertNil(MRPDecoder.decodeNowPlaying(from: data))
    }

    func testEmptyDataReturnsNil() {
        XCTAssertNil(MRPDecoder.decodeNowPlaying(from: Data()))
    }

    // MARK: - playbackState

    func testPlayingState() {
        let data = makeSetState(playbackState: 1)
        let u = MRPDecoder.decodeNowPlaying(from: data)
        XCTAssertEqual(u?.playbackState, 1)
        XCTAssertEqual(u?.playbackRate, 1.0)
    }

    func testPausedState() {
        let data = makeSetState(playbackState: 2)
        let u = MRPDecoder.decodeNowPlaying(from: data)
        XCTAssertEqual(u?.playbackState, 2)
        XCTAssertEqual(u?.playbackRate, 0.0)
    }

    func testSeekingState() {
        let data = makeSetState(playbackState: 5)
        let u = MRPDecoder.decodeNowPlaying(from: data)
        XCTAssertEqual(u?.playbackRate, 1.0)
    }

    // MARK: - metadata

    func testTitleDecoded() {
        let data = makeSetState(playbackState: 1, title: "Bohemian Rhapsody")
        let u = MRPDecoder.decodeNowPlaying(from: data)
        XCTAssertEqual(u?.title, "Bohemian Rhapsody")
    }

    func testArtistDecoded() {
        let data = makeSetState(playbackState: 1, artist: "Queen")
        let u = MRPDecoder.decodeNowPlaying(from: data)
        XCTAssertEqual(u?.artist, "Queen")
    }

    func testAlbumDecoded() {
        let data = makeSetState(playbackState: 1, album: "A Night at the Opera")
        let u = MRPDecoder.decodeNowPlaying(from: data)
        XCTAssertEqual(u?.album, "A Night at the Opera")
    }

    func testAllMetadataDecoded() {
        let data = makeSetState(playbackState: 1,
                                title: "Let It Be",
                                artist: "The Beatles",
                                album: "Let It Be")
        let u = MRPDecoder.decodeNowPlaying(from: data)
        XCTAssertEqual(u?.title, "Let It Be")
        XCTAssertEqual(u?.artist, "The Beatles")
        XCTAssertEqual(u?.album, "Let It Be")
    }

    // MARK: - isEmpty guard

    func testSetStateWithNoUsefulFieldsReturnsNil() {
        // SetStateMessage with no playback state and no metadata — isEmpty = true
        var msg: [UInt8] = field(1, varint: 4)
        msg += field(9, bytes: [])   // empty SetStateMessage
        XCTAssertNil(MRPDecoder.decodeNowPlaying(from: Data(msg)))
    }

    // MARK: - missing extension field

    func testMissingSetStateExtensionReturnsNil() {
        // msgType=4 but no field 9
        let data = Data(field(1, varint: 4))
        XCTAssertNil(MRPDecoder.decodeNowPlaying(from: data))
    }
}
