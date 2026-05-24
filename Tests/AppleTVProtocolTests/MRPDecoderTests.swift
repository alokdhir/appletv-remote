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

    /// Convenience: most existing tests expect an `MRPNowPlayingUpdate`
    /// directly. The decoder now returns `MRPDecodedMessage` (which can
    /// also carry active-client / remove-client signals) — this helper
    /// extracts the state-update case.
    private func decodeUpdate(_ data: Data, file: StaticString = #filePath, line: UInt = #line) -> MRPNowPlayingUpdate? {
        guard let m = MRPDecoder.decodeNowPlaying(from: data) else { return nil }
        if case .stateUpdate(let u) = m { return u }
        XCTFail("expected .stateUpdate, got \(m)", file: file, line: line)
        return nil
    }

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
        XCTAssertNil(decodeUpdate(data))
    }

    func testEmptyDataReturnsNil() {
        XCTAssertNil(decodeUpdate(Data()))
    }

    // MARK: - playbackState

    func testPlayingState() {
        let data = makeSetState(playbackState: 1)
        let u = decodeUpdate(data)
        XCTAssertEqual(u?.playbackState, 1)
        XCTAssertEqual(u?.playbackRate, 1.0)
    }

    func testPausedState() {
        let data = makeSetState(playbackState: 2)
        let u = decodeUpdate(data)
        XCTAssertEqual(u?.playbackState, 2)
        XCTAssertEqual(u?.playbackRate, 0.0)
    }

    func testSeekingState() {
        let data = makeSetState(playbackState: 5)
        let u = decodeUpdate(data)
        XCTAssertEqual(u?.playbackRate, 1.0)
    }

    // MARK: - metadata

    func testTitleDecoded() {
        let data = makeSetState(playbackState: 1, title: "Bohemian Rhapsody")
        let u = decodeUpdate(data)
        XCTAssertEqual(u?.title, "Bohemian Rhapsody")
    }

    func testArtistDecoded() {
        let data = makeSetState(playbackState: 1, artist: "Queen")
        let u = decodeUpdate(data)
        XCTAssertEqual(u?.artist, "Queen")
    }

    func testAlbumDecoded() {
        let data = makeSetState(playbackState: 1, album: "A Night at the Opera")
        let u = decodeUpdate(data)
        XCTAssertEqual(u?.album, "A Night at the Opera")
    }

    func testAllMetadataDecoded() {
        let data = makeSetState(playbackState: 1,
                                title: "Let It Be",
                                artist: "The Beatles",
                                album: "Let It Be")
        let u = decodeUpdate(data)
        XCTAssertEqual(u?.title, "Let It Be")
        XCTAssertEqual(u?.artist, "The Beatles")
        XCTAssertEqual(u?.album, "Let It Be")
    }

    // MARK: - isEmpty guard

    func testSetStateWithNoUsefulFieldsReturnsNil() {
        // SetStateMessage with no playback state and no metadata — isEmpty = true
        var msg: [UInt8] = field(1, varint: 4)
        msg += field(9, bytes: [])   // empty SetStateMessage
        XCTAssertNil(decodeUpdate(Data(msg)))
    }

    // MARK: - missing extension field

    func testMissingSetStateExtensionReturnsNil() {
        // msgType=4 but no field 9
        let data = Data(field(1, varint: 4))
        XCTAssertNil(decodeUpdate(data))
    }

    // MARK: - NowPlayingInfo path (legacy MPNowPlayingInfoCenter, used by Netflix etc.)

    /// Build a SET_STATE_MESSAGE that carries a NowPlayingInfo (field 1) but
    /// no PlaybackQueue/ContentItemMetadata — the shape Netflix and other
    /// third-party apps actually send via MPNowPlayingInfoCenter.
    private func makeSetStateWithNowPlayingInfo(
        playbackState: UInt64? = nil,
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        duration: Double? = nil,
        elapsedTime: Double? = nil
    ) -> Data {
        // NowPlayingInfo: album=1, artist=2, duration=3, elapsedTime=4, title=9
        var ni: [UInt8] = []
        if let al = album       { ni += field(1, bytes: Array(al.utf8)) }
        if let ar = artist      { ni += field(2, bytes: Array(ar.utf8)) }
        if let d = duration     { ni += field(3, double: d) }
        if let e = elapsedTime  { ni += field(4, double: e) }
        if let t = title        { ni += field(9, bytes: Array(t.utf8)) }

        // SetStateMessage: nowPlayingInfo=1, playbackState=6
        var ssm: [UInt8] = []
        if !ni.isEmpty              { ssm += field(1, bytes: ni) }
        if let s = playbackState    { ssm += field(6, varint: s) }

        // ProtocolMessage: msgType=4, SetStateMessage extension at field 9
        var msg: [UInt8] = field(1, varint: 4)
        msg += field(9, bytes: ssm)
        return Data(msg)
    }

    func testNowPlayingInfoTitleDecoded() {
        let data = makeSetStateWithNowPlayingInfo(playbackState: 1, title: "Stranger Things")
        let u = decodeUpdate(data)
        XCTAssertEqual(u?.title, "Stranger Things")
    }

    func testNowPlayingInfoDurationAndElapsedDecoded() {
        let data = makeSetStateWithNowPlayingInfo(
            playbackState: 1, title: "Episode 1", duration: 2700.0, elapsedTime: 615.5)
        let u = decodeUpdate(data)
        XCTAssertEqual(u?.duration, 2700.0)
        XCTAssertEqual(u?.elapsedTime, 615.5)
        XCTAssertEqual(u?.playbackRate, 1.0)
    }

    func testNowPlayingInfoFullMetadata() {
        let data = makeSetStateWithNowPlayingInfo(
            playbackState: 1,
            title: "Bohemian Rhapsody",
            artist: "Queen",
            album: "A Night at the Opera",
            duration: 354.0,
            elapsedTime: 42.0)
        let u = decodeUpdate(data)
        XCTAssertEqual(u?.title, "Bohemian Rhapsody")
        XCTAssertEqual(u?.artist, "Queen")
        XCTAssertEqual(u?.album, "A Night at the Opera")
        XCTAssertEqual(u?.duration, 354.0)
        XCTAssertEqual(u?.elapsedTime, 42.0)
    }

    /// Apps without a PlaybackQueue path used to produce isEmpty=true and get
    /// dropped — regression guard for the "Netflix has no progress bar" bug.
    func testNowPlayingInfoOnlyDoesNotReturnNil() {
        let data = makeSetStateWithNowPlayingInfo(title: "Some Show", duration: 100, elapsedTime: 5)
        let u = decodeUpdate(data)
        XCTAssertNotNil(u)
        XCTAssertEqual(u?.title, "Some Show")
        XCTAssertEqual(u?.duration, 100)
        XCTAssertEqual(u?.elapsedTime, 5)
    }

    // MARK: - Override semantics (ContentItemMetadata wins over NowPlayingInfo)

    /// Build a SET_STATE_MESSAGE that carries BOTH NowPlayingInfo (field 1)
    /// AND PlaybackQueue/ContentItemMetadata (field 3) — to verify our
    /// override ordering.
    private func makeSetStateWithBothPaths(
        nowPlayingTitle: String,
        contentItemTitle: String,
        nowPlayingDuration: Double? = nil,
        contentItemDuration: Double? = nil
    ) -> Data {
        // NowPlayingInfo
        var ni: [UInt8] = field(9, bytes: Array(nowPlayingTitle.utf8))
        if let d = nowPlayingDuration { ni += field(3, double: d) }

        // ContentItemMetadata
        var meta: [UInt8] = field(1, bytes: Array(contentItemTitle.utf8))
        if let d = contentItemDuration { meta += field(14, double: d) }
        let ci  = field(2, bytes: meta)
        let pq  = field(2, bytes: ci)

        var ssm: [UInt8] = field(1, bytes: ni)
        ssm += field(6, varint: 1)
        ssm += field(3, bytes: pq)

        var msg: [UInt8] = field(1, varint: 4)
        msg += field(9, bytes: ssm)
        return Data(msg)
    }

    func testContentItemMetadataOverridesNowPlayingInfoTitle() {
        let data = makeSetStateWithBothPaths(
            nowPlayingTitle: "Old Title", contentItemTitle: "New Title")
        let u = decodeUpdate(data)
        XCTAssertEqual(u?.title, "New Title", "ContentItemMetadata must win over NowPlayingInfo")
    }

    /// When ContentItemMetadata only has a title and no duration, the
    /// NowPlayingInfo duration must survive (no spurious nil-out).
    func testNowPlayingInfoFieldsSurviveWhenContentItemDoesNotShadow() {
        let data = makeSetStateWithBothPaths(
            nowPlayingTitle: "Old", contentItemTitle: "New", nowPlayingDuration: 600)
        let u = decodeUpdate(data)
        XCTAssertEqual(u?.title, "New")
        XCTAssertEqual(u?.duration, 600, "duration only present in NowPlayingInfo must survive")
    }

    // MARK: - NaN guard

    func testNaNDurationIsIgnored() {
        let data = makeSetStateWithNowPlayingInfo(
            playbackState: 1, title: "Live Stream", duration: .nan)
        let u = decodeUpdate(data)
        XCTAssertNil(u?.duration, "NaN duration must be filtered out")
        XCTAssertEqual(u?.title, "Live Stream")
    }

    func testNaNElapsedTimeIsIgnored() {
        let data = makeSetStateWithNowPlayingInfo(
            playbackState: 1, title: "Live Stream", elapsedTime: .nan)
        let u = decodeUpdate(data)
        XCTAssertNil(u?.elapsedTime, "NaN elapsedTime must be filtered out")
    }

    // MARK: - displayName fallback (Netflix-style "playback exists, metadata blank")

    func testDisplayNameDecoded() {
        // SetStateMessage.displayName (field 5) is the only useful field
        // Netflix emits — we use it as the footer's app-name fallback.
        var ssm: [UInt8] = field(5, bytes: Array("Netflix".utf8))
        ssm += field(6, varint: 1)
        var msg: [UInt8] = field(1, varint: 4)
        msg += field(9, bytes: ssm)
        let u = decodeUpdate(Data(msg))
        XCTAssertEqual(u?.displayName, "Netflix")
    }

    // MARK: - nowPlayingInfoData (NSKeyedArchiver bplist) — populated path

    func testNowPlayingInfoDataDictPopulatesFields() throws {
        let dict: NSDictionary = [
            "MPMediaItemPropertyTitle": "Bohemian Rhapsody",
            "MPMediaItemPropertyArtist": "Queen",
            "MPMediaItemPropertyAlbumTitle": "A Night at the Opera",
            "MPMediaItemPropertyPlaybackDuration": 354.0,
            "MPNowPlayingInfoPropertyElapsedPlaybackTime": 42.5,
        ]
        let blob = try NSKeyedArchiver.archivedData(
            withRootObject: dict, requiringSecureCoding: false)

        // Wrap in ContentItemMetadata (field 67) → ContentItem (field 2) →
        // PlaybackQueue (field 2) → SetStateMessage (field 3).
        let meta = field(67, bytes: Array(blob))
        let ci   = field(2, bytes: meta)
        let pq   = field(2, bytes: ci)
        var ssm: [UInt8] = field(6, varint: 1)
        ssm += field(3, bytes: pq)
        var msg: [UInt8] = field(1, varint: 4)
        msg += field(9, bytes: ssm)
        let u = decodeUpdate(Data(msg))
        XCTAssertEqual(u?.title,    "Bohemian Rhapsody")
        XCTAssertEqual(u?.artist,   "Queen")
        XCTAssertEqual(u?.album,    "A Night at the Opera")
        XCTAssertEqual(u?.duration, 354.0)
        XCTAssertEqual(u?.elapsedTime, 42.5)
    }

    /// Netflix's empty NSKeyedArchiver dict must NOT spuriously populate
    /// fields. Regression guard: the unarchive helper must return nil for
    /// an empty root dict, not an empty `[:]` that pollutes the update.
    func testEmptyNowPlayingInfoDataDictIsIgnored() throws {
        let blob = try NSKeyedArchiver.archivedData(
            withRootObject: NSDictionary(), requiringSecureCoding: false)
        let meta = field(67, bytes: Array(blob))
        let ci   = field(2, bytes: meta)
        let pq   = field(2, bytes: ci)
        var ssm: [UInt8] = field(6, varint: 1)
        ssm += field(3, bytes: pq)
        var msg: [UInt8] = field(1, varint: 4)
        msg += field(9, bytes: ssm)
        let u = decodeUpdate(Data(msg))
        XCTAssertNil(u?.title)
        XCTAssertNil(u?.duration)
        XCTAssertNil(u?.elapsedTime)
    }

    // MARK: - bundleIdentifier extraction (PlayerPath → NowPlayingClient)

    /// Build a SetStateMessage that carries a PlayerPath (field 9) wrapping
    /// a NowPlayingClient (field 2) with bundleIdentifier (field 2).
    private func makeSetStateWithBundle(_ bundle: String, playbackState: UInt64 = 1) -> Data {
        let client = field(2, bytes: Array(bundle.utf8))
        let path   = field(2, bytes: client)
        var ssm: [UInt8] = field(6, varint: playbackState)
        ssm += field(9, bytes: path)
        var msg: [UInt8] = field(1, varint: 4)
        msg += field(9, bytes: ssm)
        return Data(msg)
    }

    func testBundleIdentifierExtracted() {
        let data = makeSetStateWithBundle("com.netflix.Netflix")
        let u = decodeUpdate(data)
        XCTAssertEqual(u?.bundleIdentifier, "com.netflix.Netflix")
    }

    // MARK: - SET_NOW_PLAYING_CLIENT_MESSAGE (type 46)

    /// type 46 wraps SetNowPlayingClientMessage at extension field 50,
    /// which contains a NowPlayingClient at field 1.
    private func makeSetNowPlayingClient(_ bundle: String?) -> Data {
        var client: [UInt8] = []
        if let bundle { client += field(2, bytes: Array(bundle.utf8)) }
        let inner = field(1, bytes: client)
        var msg: [UInt8] = field(1, varint: 46)
        msg += field(50, bytes: inner)
        return Data(msg)
    }

    func testSetNowPlayingClientDecodesActiveBundle() {
        let data = makeSetNowPlayingClient("com.netflix.Netflix")
        guard let m = MRPDecoder.decodeNowPlaying(from: data) else {
            XCTFail("expected decoded message"); return
        }
        guard case .activeClient(let bid) = m else {
            XCTFail("expected .activeClient, got \(m)"); return
        }
        XCTAssertEqual(bid, "com.netflix.Netflix")
    }

    func testSetNowPlayingClientWithoutBundleDecodesNil() {
        // tvOS clears the active client by sending an empty NowPlayingClient.
        let data = makeSetNowPlayingClient(nil)
        guard case .activeClient(let bid)? = MRPDecoder.decodeNowPlaying(from: data) else {
            XCTFail("expected .activeClient"); return
        }
        XCTAssertNil(bid)
    }

    // MARK: - REMOVE_CLIENT_MESSAGE (type 53)

    func testRemoveClientDecoded() {
        // Wraps a RemoveClientMessage at extension field 53, which has a
        // NowPlayingClient at field 1.
        let client = field(2, bytes: Array("com.netflix.Netflix".utf8))
        let inner  = field(1, bytes: client)
        var msg: [UInt8] = field(1, varint: 53)
        msg += field(53, bytes: inner)
        guard case .removeClient(let bid)? = MRPDecoder.decodeNowPlaying(from: Data(msg)) else {
            XCTFail("expected .removeClient"); return
        }
        XCTAssertEqual(bid, "com.netflix.Netflix")
    }
}
