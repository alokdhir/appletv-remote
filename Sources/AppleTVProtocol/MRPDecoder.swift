import Foundation

/// One decoded MRP message that carries player-state information.
///
/// MRP delivers now-playing data in three flavours that we care about:
///
/// 1. `SET_STATE` (type 4) and `UPDATE_CONTENT_ITEM` (type 56) push the
///    actual playback state — title, elapsed time, rate, etc. — for a
///    *specific* player identified by its bundle id.
/// 2. `SET_NOW_PLAYING_CLIENT` (type 46) is tvOS announcing which player
///    should currently be considered the foreground / active one.
/// 3. `REMOVE_CLIENT` (type 53) tells us a player has gone away.
///
/// Several apps publish state simultaneously (Netflix, the TV app, AirPlay,
/// HBO Max, …) so the caller MUST track per-bundle state and use the
/// `.activeClient` signal to decide which player to surface in the UI.
public enum MRPDecodedMessage: Sendable {
    case stateUpdate(MRPNowPlayingUpdate)
    case activeClient(String?)
    case removeClient(String)
}

/// Decodes inbound MRP ProtocolMessage payloads into typed Swift values.
///
/// Wire structure (all lengths/types verified against pyatv protobuf defs):
///
///   SET_STATE_MESSAGE (type=4, ext field=9 → SetStateMessage)
///     SetStateMessage
///       field 1: NowPlayingInfo            — legacy MPNowPlayingInfoCenter shape
///       field 3: PlaybackQueue
///         field 2 (repeated): ContentItem
///           field 2: ContentItemMetadata
///             field  1: title            : string
///             field  6: albumName        : string
///             field  7: trackArtistName  : string
///             field 14: duration         : double
///             field 35: elapsedTime      : double
///             field 67: nowPlayingInfoData : bytes (NSKeyedArchiver bplist of
///                                            an MPNowPlayingInfo dict; many
///                                            third-party apps put data here)
///       field 5: displayName    : string  (e.g. "Netflix" — app fallback)
///       field 6: playbackState  : enum  (1=playing, 2=paused, 3=stopped, 5=seeking)
///       field 11: playbackStateTimestamp : double
///
/// Note: some apps (Netflix in particular) deliberately ship an *empty*
/// `nowPlayingInfoData` dict and no inline metadata at all — there is no
/// title/duration/elapsed to recover. The built-in iOS Apple TV Remote has
/// the same blank scrubber in those cases.
public enum MRPDecoder {

    // MARK: - Public entry point

    /// Attempt to decode a now-playing update from a raw ProtocolMessage payload.
    /// Returns nil if the message type carries no playback-relevant data.
    ///
    /// tvOS sends the full state on session bring-up via SET_STATE_MESSAGE
    /// (type 4) and then incremental metadata-only deltas via
    /// UPDATE_CONTENT_ITEM_MESSAGE (type 56) for elapsed-time / artwork /
    /// title changes. Without parsing 56 our anchor never moves between
    /// session-restart events, so the displayed elapsed drifts.
    public static func decodeNowPlaying(from data: Data) -> MRPDecodedMessage? {
        guard let msgType = data.protobufVarintField(fieldNumber: 1) else { return nil }
        switch msgType {
        case 4:  return decodeSetState(data).map { .stateUpdate($0) }
        case 56: return decodeUpdateContentItem(data).map { .stateUpdate($0) }
        case 46: return decodeSetNowPlayingClient(data)
        case 53: return decodeRemoveClient(data)
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

        // displayName (field 5) — app name fallback when no title is sent
        // (Netflix etc. ship just "Netflix" here and nothing else).
        if let name = ssm.protobufStringField(fieldNumber: 5) {
            u.displayName = name
        }

        // NowPlayingInfo (field 1) — legacy embedded protobuf shape.
        // Read first so ContentItemMetadata can override fields if also present.
        if let ni = ssm.protobufBytesField(fieldNumber: 1) {
            applyNowPlayingInfo(ni, into: &u)
        }

        // playbackQueue (field 3) → first ContentItem → ContentItemMetadata
        if let pq = ssm.protobufBytesField(fieldNumber: 3),
           let ci = pq.protobufBytesField(fieldNumber: 2) {
            applyContentItem(ci, into: &u)
        }

        // bundleIdentifier of the player sending this state — extracted so
        // the upper layer can pick which player to display when several apps
        // are publishing now-playing simultaneously.
        // PlayerPath lives at SetStateMessage field 9; NowPlayingClient at
        // PlayerPath field 2; bundleIdentifier at NowPlayingClient field 2.
        if let pp = ssm.protobufBytesField(fieldNumber: 9),
           let cl = pp.protobufBytesField(fieldNumber: 2),
           let bid = cl.protobufStringField(fieldNumber: 2) {
            u.bundleIdentifier = bid
        }

        return u.isEmpty ? nil : u
    }

    // MARK: - SET_NOW_PLAYING_CLIENT_MESSAGE (type 46, ext field 50)

    /// tvOS announces which player should be considered the active
    /// now-playing client. We use this to filter the cross-talk we'd
    /// otherwise get when several players publish state simultaneously.
    /// NowPlayingClient.bundleIdentifier lives at field 2.
    private static func decodeSetNowPlayingClient(_ outer: Data) -> MRPDecodedMessage? {
        guard let inner = outer.protobufBytesField(fieldNumber: 50),
              let cl = inner.protobufBytesField(fieldNumber: 1)
        else { return .activeClient(nil) }
        let bid = cl.protobufStringField(fieldNumber: 2)
        return .activeClient(bid)
    }

    // MARK: - REMOVE_CLIENT_MESSAGE (type 53, ext field 53)

    /// tvOS tells us a player went away (app quit). Used to drop stale
    /// state from the per-bundle cache.
    private static func decodeRemoveClient(_ outer: Data) -> MRPDecodedMessage? {
        guard let inner = outer.protobufBytesField(fieldNumber: 53),
              let cl = inner.protobufBytesField(fieldNumber: 1),
              let bid = cl.protobufStringField(fieldNumber: 2)
        else { return nil }
        return .removeClient(bid)
    }

    // MARK: - UPDATE_CONTENT_ITEM_MESSAGE (type 56, ext field 60)

    /// tvOS posts these as incremental updates between SET_STATE pushes —
    /// new elapsed time, artwork, or metadata for the currently-playing
    /// item. Carries no playback-rate / state info, so we only update the
    /// metadata cohort and let SET_STATE drive rate transitions.
    private static func decodeUpdateContentItem(_ outer: Data) -> MRPNowPlayingUpdate? {
        guard let inner = outer.protobufBytesField(fieldNumber: 60) else { return nil }
        var u = MRPNowPlayingUpdate()

        // contentItems (field 1, repeated). The first item is the active
        // one; we ignore later items (representing queued-up content).
        if let ci = inner.protobufBytesField(fieldNumber: 1) {
            applyContentItem(ci, into: &u)
        }

        return u.isEmpty ? nil : u
    }

    /// Pull title / artist / album / duration / elapsedTime out of a
    /// ContentItem's metadata payload (field 2). Also tries the
    /// NSKeyedArchiver-encoded `nowPlayingInfoData` blob (field 67) for
    /// apps that populate `MPNowPlayingInfoCenter` directly.
    private static func applyContentItem(_ ci: Data, into u: inout MRPNowPlayingUpdate) {
        guard let meta = ci.protobufBytesField(fieldNumber: 2) else { return }
        if let v = meta.protobufStringField(fieldNumber: 1)  { u.title    = v }
        if let v = meta.protobufStringField(fieldNumber: 6)  { u.album    = v }
        if let v = meta.protobufStringField(fieldNumber: 7)  { u.artist   = v }
        if let v = meta.protobufDoubleField(fieldNumber: 14), !v.isNaN { u.duration    = v }
        if let v = meta.protobufDoubleField(fieldNumber: 35), !v.isNaN { u.elapsedTime = v }
        // nowPlayingInfoData (field 67) — NSKeyedArchiver bplist that some
        // apps fill with the same MPNowPlayingInfo dict they hand to
        // MPNowPlayingInfoCenter. Empty for Netflix; populated for others.
        if let blob = meta.protobufBytesField(fieldNumber: 67),
           let dict = unarchiveNowPlayingInfo(blob) {
            applyNowPlayingDict(dict, into: &u)
        }
    }

    /// Pull metadata out of NowPlayingInfo (SetStateMessage field 1).
    /// This is the path populated by MPNowPlayingInfoCenter — all third-party
    /// apps go here. Fields: album=1, artist=2, duration=3, elapsedTime=4,
    /// playbackRate=5, timestamp=8, title=9.
    private static func applyNowPlayingInfo(_ ni: Data, into u: inout MRPNowPlayingUpdate) {
        if let v = ni.protobufStringField(fieldNumber: 9) { u.title  = v }
        if let v = ni.protobufStringField(fieldNumber: 2) { u.artist = v }
        if let v = ni.protobufStringField(fieldNumber: 1) { u.album  = v }
        if let v = ni.protobufDoubleField(fieldNumber: 3), !v.isNaN  { u.duration    = v }
        if let v = ni.protobufDoubleField(fieldNumber: 4), !v.isNaN  { u.elapsedTime = v }
    }

    // MARK: - nowPlayingInfoData (NSKeyedArchiver bplist)

    /// MPNowPlayingInfoCenter dictionary keys we know how to map onto
    /// `MRPNowPlayingUpdate`.
    private static let kTitle           = "MPMediaItemPropertyTitle"
    private static let kArtist          = "MPMediaItemPropertyArtist"
    private static let kAlbum           = "MPMediaItemPropertyAlbumTitle"
    private static let kDuration        = "MPMediaItemPropertyPlaybackDuration"
    private static let kElapsed         = "MPNowPlayingInfoPropertyElapsedPlaybackTime"
    private static let kPlaybackRate    = "MPNowPlayingInfoPropertyPlaybackRate"

    private static func applyNowPlayingDict(_ dict: [String: Any],
                                            into u: inout MRPNowPlayingUpdate) {
        if let s = dict[kTitle]  as? String, !s.isEmpty { u.title  = s }
        if let s = dict[kArtist] as? String, !s.isEmpty { u.artist = s }
        if let s = dict[kAlbum]  as? String, !s.isEmpty { u.album  = s }
        if let n = dict[kDuration] as? NSNumber {
            let d = n.doubleValue
            if d.isFinite, d > 0 { u.duration = d }
        }
        if let n = dict[kElapsed] as? NSNumber {
            let d = n.doubleValue
            if d.isFinite { u.elapsedTime = d }
        }
        if let n = dict[kPlaybackRate] as? NSNumber, u.playbackRate == nil {
            let d = n.doubleValue
            if d.isFinite { u.playbackRate = d }
        }
    }

    /// Decode an NSKeyedArchiver-encoded NSDictionary blob (the value of
    /// `ContentItemMetadata.nowPlayingInfoData`). Returns nil for non-dict
    /// or empty roots. Walks `$objects` manually because the dictionary
    /// values are often classes (NSDate etc.) that secure unarchiving
    /// rejects without an explicit allow-list.
    static func unarchiveNowPlayingInfo(_ blob: Data) -> [String: Any]? {
        guard let plist = try? PropertyListSerialization.propertyList(
                from: blob, options: [], format: nil) as? [String: Any],
              let objects = plist["$objects"] as? [Any],
              let top = plist["$top"] as? [String: Any],
              let rootUID = uidValue(top["root"]),
              rootUID < objects.count,
              let rootDict = objects[Int(rootUID)] as? [String: Any],
              let keysRefs = rootDict["NS.keys"] as? [Any],
              let valsRefs = rootDict["NS.objects"] as? [Any],
              keysRefs.count == valsRefs.count
        else { return nil }

        var out: [String: Any] = [:]
        for (kRef, vRef) in zip(keysRefs, valsRefs) {
            guard let kUID = uidValue(kRef), kUID < objects.count,
                  let key = objects[Int(kUID)] as? String
            else { continue }
            guard let vUID = uidValue(vRef), vUID < objects.count else { continue }
            out[key] = resolve(objects[Int(vUID)], in: objects)
        }
        return out.isEmpty ? nil : out
    }

    /// Convert a decoded plist UID reference (CFKeyedArchiverUID) into its
    /// integer index. NSKeyedArchiver wraps these as `CFKeyedArchiverUID`,
    /// which `PropertyListSerialization` returns as its underlying Foundation
    /// type — we read it via NSNumber bridging since the type is private.
    private static func uidValue(_ any: Any?) -> UInt64? {
        guard let any else { return nil }
        // CFKeyedArchiverUID bridges to NSNumber on read.
        if let n = any as? NSNumber { return n.uint64Value }
        // Fallback: introspect via String(describing:) for the {value = N}
        // form when bridging ever changes.
        let s = String(describing: any)
        if let r = s.range(of: #"value = (\d+)"#, options: .regularExpression) {
            let num = s[r].dropFirst("value = ".count)
            return UInt64(num)
        }
        return nil
    }

    /// Resolve a single `$objects` entry into a usable Swift value. Strings
    /// and numbers come back as-is; `$class` wrappers (NSDate, NSURL etc.)
    /// are unwrapped to their primitive payload when feasible.
    private static func resolve(_ obj: Any, in objects: [Any]) -> Any {
        if let dict = obj as? [String: Any] {
            // NSDate → NS.time (double, Cocoa epoch). Convert to Date.
            if let t = dict["NS.time"] as? Double {
                return Date(timeIntervalSinceReferenceDate: t)
            }
            // NSURL → NS.relative (string).
            if let s = dict["NS.relative"] as? String {
                return s
            }
            return dict
        }
        return obj
    }
}

// MARK: - MRPNowPlayingUpdate

/// Partial now-playing state decoded from a single MRP message.
public struct MRPNowPlayingUpdate: Sendable {
    public var title: String?
    public var artist: String?
    public var album: String?
    /// User-facing app/player name from `SetStateMessage.displayName`
    /// (e.g. "Netflix"). Used as a footer fallback when no title is sent.
    public var displayName: String?
    /// Bundle identifier of the player that emitted this update
    /// (e.g. `com.netflix.Netflix`, `com.apple.TVAppleTVApp`). Lets the
    /// upper layer pick which player to surface when several are publishing
    /// state simultaneously.
    public var bundleIdentifier: String?
    public var playbackRate: Double?
    public var playbackState: Int?
    public var duration: Double?
    public var elapsedTime: Double?
    public var playbackStateTimestamp: Double?

    public var isEmpty: Bool {
        title == nil && artist == nil && album == nil &&
        displayName == nil && bundleIdentifier == nil &&
        playbackRate == nil && duration == nil && elapsedTime == nil
    }

    /// Resolve which per-bundle bucket this update belongs to.
    ///
    /// `SET_STATE_MESSAGE` (type 4) carries `bundleIdentifier` directly.
    /// `UPDATE_CONTENT_ITEM_MESSAGE` (type 56) does not — by protocol
    /// definition it refers to the currently-active player, identified
    /// out-of-band by the most recent `SET_NOW_PLAYING_CLIENT_MESSAGE`
    /// (type 46). Treating type 56 as a separate `_unknown` bundle was
    /// the cause of the displayed-elapsed lag bug, since type 56 carries
    /// fresh elapsed every ~1s and nothing else does.
    ///
    /// Fallback chain:
    ///   1. Update's own `bundleIdentifier` if set (type 4 path).
    ///   2. The bundle tvOS most recently announced as active (type 46).
    ///   3. Caller's `fallback()` — typically the most-recently-updated
    ///      bundle in the per-bundle map.
    ///   4. `"_unknown"` as last resort. `unknownLogger` (if non-nil)
    ///      receives a one-line breadcrumb so we can spot regressions
    ///      in the wire protocol if a future tvOS build changes the
    ///      bundleIdentifier semantics.
    public func routedBundle(
        active: String?,
        fallback: () -> String?,
        unknownLogger: ((String) -> Void)? = nil
    ) -> String {
        if let b = bundleIdentifier { return b }
        if let b = active           { return b }
        if let b = fallback()       { return b }
        unknownLogger?("MRP update has no bundle id, no active client, no fallback bucket — using _unknown")
        return "_unknown"
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
