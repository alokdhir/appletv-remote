import Foundation

/// Decodes inbound MRP ProtocolMessage payloads into typed Swift values.
///
/// Wire structure (all lengths/types verified against pyatv protobuf defs):
///
///   SET_STATE_MESSAGE (type=4, ext field=9 → SetStateMessage)
///     SetStateMessage
///       field 3: PlaybackQueue
///         field 2 (repeated): ContentItem
///           field 2: ContentItemMetadata
///             field  1: title            : string
///             field  6: albumName        : string
///             field  7: trackArtistName  : string
///             field 14: duration         : double
///             field 35: elapsedTime      : double
///       field 6: playbackState   : enum  (1=playing, 2=paused, 3=stopped, 5=seeking)
///       field 11: playbackStateTimestamp : double
///
public enum MRPDecoder {

    // MARK: - Public entry point

    /// Attempt to decode a now-playing update from a raw ProtocolMessage payload.
    /// Returns nil if the message type carries no playback-relevant data.
    public static func decodeNowPlaying(from data: Data) -> MRPNowPlayingUpdate? {
        guard let msgType = data.protobufVarintField(fieldNumber: 1) else { return nil }
        switch msgType {
        case 4:  return decodeSetState(data)
        default: return nil
        }
    }

    /// Return the raw message type (field 1) of a ProtocolMessage.
    public static func messageType(from data: Data) -> UInt64? {
        data.protobufVarintField(fieldNumber: 1)
    }

    // MARK: - SET_STATE_MESSAGE (type 4, ext field 9)

    private static func decodeSetState(_ outer: Data) -> MRPNowPlayingUpdate? {
        // Extension field 9 carries SetStateMessage bytes.
        guard let ssm = outer.protobufBytesField(fieldNumber: 9) else { return nil }

        var u = MRPNowPlayingUpdate()

        // playbackState (field 6): 1=playing, 2=paused, 3=stopped, 5=seeking
        if let st = ssm.protobufVarintField(fieldNumber: 6) {
            u.playbackRate = (st == 1 || st == 5) ? 1.0 : 0.0
            u.playbackState = Int(st)
        }

        // playbackStateTimestamp (field 11)
        if let ts = ssm.protobufDoubleField(fieldNumber: 11) {
            u.playbackStateTimestamp = ts
        }

        // playbackQueue (field 3) → first ContentItem → ContentItemMetadata
        if let pq = ssm.protobufBytesField(fieldNumber: 3),
           let ci = pq.protobufBytesField(fieldNumber: 2),   // first ContentItem
           let meta = ci.protobufBytesField(fieldNumber: 2) { // ContentItemMetadata
            u.title    = meta.protobufStringField(fieldNumber: 1)
            u.album    = meta.protobufStringField(fieldNumber: 6)
            u.artist   = meta.protobufStringField(fieldNumber: 7)
            if let d = meta.protobufDoubleField(fieldNumber: 14) { u.duration    = d }
            if let e = meta.protobufDoubleField(fieldNumber: 35) { u.elapsedTime = e }
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
    public var playbackState: Int?
    public var duration: Double?
    public var elapsedTime: Double?
    public var playbackStateTimestamp: Double?

    public var isEmpty: Bool {
        title == nil && artist == nil && album == nil &&
        playbackRate == nil && duration == nil && elapsedTime == nil
    }

    public init() {}
}

// MARK: - Additional protobuf decode helpers (string + double)

public extension Data {
    func protobufStringField(fieldNumber: Int) -> String? {
        guard let d = protobufBytesField(fieldNumber: fieldNumber),
              let s = String(data: d, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }

    /// Read an IEEE-754 double (wire type 1, 64-bit little-endian) field.
    func protobufDoubleField(fieldNumber: Int) -> Double? {
        var offset = 0
        while offset < count {
            guard let tag = readVarintFrom(offset: &offset) else { return nil }
            let wt = Int(tag & 0x7)
            let fn = Int(tag >> 3)
            switch wt {
            case 0:
                guard readVarintFrom(offset: &offset) != nil else { return nil }
            case 1:
                guard offset + 8 <= count else { return nil }
                let start = index(startIndex, offsetBy: offset)
                let end   = index(startIndex, offsetBy: offset + 8)
                offset += 8
                if fn == fieldNumber {
                    var v: Double = 0
                    _ = Swift.withUnsafeMutableBytes(of: &v) { dst in
                        self[start..<end].copyBytes(to: dst)
                    }
                    return v
                }
            case 2:
                guard let len = readVarintFrom(offset: &offset) else { return nil }
                offset += Int(len)
            case 5:
                offset += 4
            default:
                return nil
            }
        }
        return nil
    }
}
