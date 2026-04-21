import Foundation

/// Decodes inbound MRP ProtocolMessage payloads into typed Swift values.
///
/// Relevant message types (from pyatv protobuf defs):
///
///   Type 30  SET_STATE_MESSAGE
///     Extension field 30 → SetStateMessage
///       field 1  playbackState : int32   (1=playing, 2=paused, 3=stopped, 5=seeking)
///
///   Type 40  NOW_PLAYING_INFO_MESSAGE
///   Type 45  CONTENT_ITEM_UPDATE_MESSAGE
///     Extension field 40/45 → ContentItemMessage
///       field 1 (repeated) ContentItem
///         field 5 metadata : ContentItemMetadata
///           field 1  title        : string
///           field 4  artist       : string
///           field 7  albumTitle   : string
///
/// References:
///   pyatv/protocols/mrp/protobuf/SetStateMessage.proto
///   pyatv/protocols/mrp/protobuf/ContentItemMessage.proto
public enum MRPDecoder {

    // MARK: - Public entry point

    /// Attempt to decode a now-playing update from a raw ProtocolMessage payload.
    /// Returns nil if the message type carries no playback-relevant data.
    public static func decodeNowPlaying(from data: Data) -> MRPNowPlayingUpdate? {
        guard let msgType = data.protobufVarintField(fieldNumber: 1) else { return nil }
        switch msgType {
        case 30:      return decodeSetState(data)
        case 40, 45:  return decodeContentItem(data)
        default:      return nil
        }
    }

    /// Return the raw message type (field 1) of a ProtocolMessage.
    public static func messageType(from data: Data) -> UInt64? {
        data.protobufVarintField(fieldNumber: 1)
    }

    // MARK: - SET_STATE_MESSAGE (type 30)

    private static func decodeSetState(_ data: Data) -> MRPNowPlayingUpdate? {
        guard let inner = data.protobufBytesField(fieldNumber: 30) else { return nil }
        guard let stateInt = inner.protobufVarintField(fieldNumber: 1) else { return nil }

        let rate: Double
        switch stateInt {
        case 1:  rate = 1.0
        case 2:  rate = 0.0
        case 3:  rate = 0.0
        case 5:  rate = 1.0
        default: rate = 0.0
        }

        var u = MRPNowPlayingUpdate()
        u.playbackRate = rate
        return u
    }

    // MARK: - CONTENT_ITEM_UPDATE_MESSAGE (type 40 / 45)

    private static func decodeContentItem(_ data: Data) -> MRPNowPlayingUpdate? {
        let inner = data.protobufBytesField(fieldNumber: 45)
                 ?? data.protobufBytesField(fieldNumber: 40)
        guard let inner else { return nil }

        var offset = 0
        while offset < inner.count {
            guard let tag = inner.readVarintFrom(offset: &offset) else { break }
            let wireType = Int(tag & 0x7)
            let field    = Int(tag >> 3)

            switch wireType {
            case 2:
                guard let len = inner.readVarintFrom(offset: &offset) else { return nil }
                let end = offset + Int(len)
                if field == 1, end <= inner.count {
                    let itemData = Data(inner[inner.index(inner.startIndex, offsetBy: offset)..<inner.index(inner.startIndex, offsetBy: end)])
                    if let update = decodeContentItemEntry(itemData) { return update }
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

    private static func decodeContentItemEntry(_ data: Data) -> MRPNowPlayingUpdate? {
        guard let meta = data.protobufBytesField(fieldNumber: 5) else { return nil }

        var u = MRPNowPlayingUpdate()
        var offset = 0
        while offset < meta.count {
            guard let tag = meta.readVarintFrom(offset: &offset) else { break }
            let wireType = Int(tag & 0x7)
            let field    = Int(tag >> 3)

            switch (wireType, field) {
            case (2, 1):  u.title  = meta.readStringField(at: &offset)
            case (2, 4):  u.artist = meta.readStringField(at: &offset)
            case (2, 7):  u.album  = meta.readStringField(at: &offset)
            case (0, _):
                guard meta.readVarintFrom(offset: &offset) != nil else { return u }
            case (2, _):
                guard let len = meta.readVarintFrom(offset: &offset) else { return u }
                offset += Int(len)
            default:
                return u
            }
        }
        return u.isEmpty ? nil : u
    }
}

// MARK: - MRPNowPlayingUpdate

/// Partial now-playing state decoded from a single MRP message.
public struct MRPNowPlayingUpdate: Sendable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var playbackRate: Double?

    public var isEmpty: Bool {
        title == nil && artist == nil && album == nil && playbackRate == nil
    }

    public init() {}
}
