import Foundation

/// Decodes inbound MRP ProtocolMessage payloads into typed Swift values.
///
/// MRP message types relevant to now-playing state (from pyatv protobuf defs):
///
///   Type 30  SET_STATE_MESSAGE
///     Extension field 30 → SetStateMessage
///       field 1  playbackState : int32   (1=playing, 2=paused, 3=stopped, 5=seeking)
///
///   Type 45  CONTENT_ITEM_UPDATE_MESSAGE (also seen as type 40 in some firmware)
///     Extension field 45 → ContentItemMessage
///       field 1  contentItems : repeated ContentItem
///         ContentItem:
///           field 5  metadata : ContentItemMetadata
///             field 1  title        : string
///             field 4  artist       : string (or trackArtistName)
///             field 7  albumTitle   : string
///             field 13 artworkData  : bytes
///             field 14 artworkWidth : int32
///             field 15 artworkHeight: int32
///
///   Type 35  PLAYBACK_QUEUE_CHANGED_MESSAGE — triggers now-playing refresh
///
///   Type 40  NOW_PLAYING_INFO_MESSAGE (alternate; same inner structure)
///
/// References:
///   pyatv/protocols/mrp/protobuf/SetStateMessage.proto
///   pyatv/protocols/mrp/protobuf/ContentItemMessage.proto
enum MRPDecoder {

    // MARK: - Public entry point

    /// Attempt to extract now-playing info from a raw ProtocolMessage payload.
    /// Returns nil if the message type carries no playback state.
    static func decodeNowPlaying(from data: Data) -> NowPlayingUpdate? {
        guard let msgType = data.protobufVarintField(fieldNumber: 1) else { return nil }

        switch msgType {
        case 30:  // SET_STATE_MESSAGE
            return decodeSetState(data)
        case 40, 45:  // NOW_PLAYING_INFO / CONTENT_ITEM_UPDATE
            return decodeContentItem(data)
        default:
            return nil
        }
    }

    // MARK: - SET_STATE_MESSAGE (type 30)

    private static func decodeSetState(_ data: Data) -> NowPlayingUpdate? {
        guard let inner = data.protobufBytesField(fieldNumber: 30) else { return nil }
        guard let stateInt = inner.protobufVarintField(fieldNumber: 1) else { return nil }

        let rate: Float
        switch stateInt {
        case 1:  rate = 1.0   // playing
        case 2:  rate = 0.0   // paused
        case 3:  rate = 0.0   // stopped
        case 5:  rate = 1.0   // seeking
        default: rate = 0.0
        }

        var update = NowPlayingUpdate()
        update.playbackRate = rate
        return update
    }

    // MARK: - CONTENT_ITEM_UPDATE_MESSAGE (type 40 / 45)

    private static func decodeContentItem(_ data: Data) -> NowPlayingUpdate? {
        // Try both known extension field numbers
        let inner = data.protobufBytesField(fieldNumber: 45)
                 ?? data.protobufBytesField(fieldNumber: 40)
        guard let inner else { return nil }

        // Repeated ContentItem messages are all at field 1
        // Collect all and use the first one that has metadata
        var offset = 0
        while offset < inner.count {
            guard let tag = inner.readVarintFrom(offset: &offset) else { break }
            let wireType = Int(tag & 0x7)
            let field    = Int(tag >> 3)

            switch wireType {
            case 2:  // length-delimited
                guard let len = inner.readVarintFrom(offset: &offset) else { return nil }
                let end = offset + Int(len)
                if field == 1, end <= inner.count {
                    let itemData = Data(inner[inner.index(inner.startIndex, offsetBy: offset)..<inner.index(inner.startIndex, offsetBy: end)])
                    if let update = decodeContentItemEntry(itemData) {
                        return update
                    }
                }
                offset = end
            case 0:
                guard inner.readVarintFrom(offset: &offset) != nil else { return nil }
            default:
                return nil
            }
        }
        return nil
    }

    private static func decodeContentItemEntry(_ data: Data) -> NowPlayingUpdate? {
        // ContentItem field 5 = metadata (ContentItemMetadata)
        guard let meta = data.protobufBytesField(fieldNumber: 5) else { return nil }

        var update = NowPlayingUpdate()

        // Scan all fields in ContentItemMetadata
        var offset = 0
        while offset < meta.count {
            guard let tag = meta.readVarintFrom(offset: &offset) else { break }
            let wireType = Int(tag & 0x7)
            let field    = Int(tag >> 3)

            switch (wireType, field) {
            case (2, 1):   // title
                update.title = meta.readStringField(at: &offset)
            case (2, 4):   // artist (trackArtistName)
                update.artist = meta.readStringField(at: &offset)
            case (2, 7):   // albumTitle
                update.album = meta.readStringField(at: &offset)
            case (2, 13):  // artworkData
                update.artworkData = meta.readBytesField(at: &offset)
            case (0, _):   // skip other varints
                guard meta.readVarintFrom(offset: &offset) != nil else { return update }
            case (2, _):   // skip other length-delimited fields
                guard let len = meta.readVarintFrom(offset: &offset) else { return update }
                offset += Int(len)
            default:
                return update
            }
        }

        return update.isEmpty ? nil : update
    }
}

// MARK: - NowPlayingUpdate

/// Partial update to now-playing state — only fields the decoded message contains.
struct NowPlayingUpdate {
    var title: String?
    var artist: String?
    var album: String?
    var artworkData: Data?
    var playbackRate: Float?

    var isEmpty: Bool {
        title == nil && artist == nil && album == nil
        && artworkData == nil && playbackRate == nil
    }

    /// Merge this update into an existing NowPlayingInfo, returning the result.
    func applied(to existing: NowPlayingInfo?) -> NowPlayingInfo {
        var info = existing ?? NowPlayingInfo()
        if let v = title        { info.title = v }
        if let v = artist       { info.artist = v }
        if let v = album        { info.album = v }
        if let v = artworkData  { info.artworkData = v }
        if let v = playbackRate { info.playbackRate = v }
        return info
    }
}

// MARK: - Data parsing helpers

private extension Data {
    /// Read a varint starting at a raw integer offset (not Data.Index).
    func readVarintFrom(offset: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < count {
            let byte = self[index(startIndex, offsetBy: offset)]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil
    }

    func readStringField(at offset: inout Int) -> String? {
        guard let bytes = readBytesField(at: &offset) else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    func readBytesField(at offset: inout Int) -> Data? {
        guard let len = readVarintFrom(offset: &offset) else { return nil }
        let start = offset
        let end   = offset + Int(len)
        guard end <= count else { return nil }
        offset = end
        return Data(self[index(startIndex, offsetBy: start)..<index(startIndex, offsetBy: end)])
    }
}
