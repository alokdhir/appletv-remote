import Foundation

// MARK: - NowPlayingInfo

/// Snapshot of the Apple TV's current media-playback state, as pushed via
/// Companion `_iMC` event subscription. All fields are optional because tvOS
/// is inconsistent about which keys populate for which apps — the `raw` map
/// preserves everything we saw (stringified) so unknown keys stay inspectable.
public struct NowPlayingInfo: Equatable, Sendable {
    public var title: String?
    public var artist: String?
    public var album: String?
    /// User-facing app name (e.g. "TV", "Music", "Netflix"). Usually under key
    /// `clientName` or `displayName` — we check both.
    public var app: String?
    public var elapsedTime: Double?
    public var duration: Double?
    /// 0.0 = paused, 1.0 = playing at normal speed. Some apps report other rates.
    public var playbackRate: Double?
    /// Wall-clock time on this Mac when `elapsedTime` was last stamped by the ATV.
    public var elapsedAnchor: Date?
    /// Every key/value we saw, stringified. Useful for debugging and for any
    /// field we haven't named above yet.
    public var raw: [String: String]

    public init() {
        self.title = nil; self.artist = nil; self.album = nil; self.app = nil
        self.elapsedTime = nil; self.duration = nil; self.playbackRate = nil
        self.elapsedAnchor = nil
        self.raw = [:]
    }

    /// Elapsed time ticking forward from the last ATV push while playing.
    /// Returns the raw `elapsedTime` when paused or unanchored.
    public func liveElapsed(at date: Date = Date()) -> Double? {
        guard let elapsed = elapsedTime else { return nil }
        guard let anchor = elapsedAnchor, let rate = playbackRate, rate > 0 else {
            return elapsed
        }
        let computed = elapsed + date.timeIntervalSince(anchor) * rate
        if let dur = duration { return min(computed, dur) }
        return computed
    }

    public init(from dict: [String: Any]) {
        func str(_ keys: String...) -> String? {
            for k in keys {
                if let v = dict[k] as? String, !v.isEmpty { return v }
            }
            return nil
        }
        func num(_ keys: String...) -> Double? {
            for k in keys {
                if let v = dict[k] as? Double { return v }
                if let v = dict[k] as? Int    { return Double(v) }
                if let v = dict[k] as? String, let d = Double(v) { return d }
            }
            return nil
        }
        self.title        = str("title", "kMRMediaRemoteNowPlayingInfoTitle")
        self.artist       = NowPlayingInfo.filterSeasonEpisode(
            str("artist", "kMRMediaRemoteNowPlayingInfoArtist"))
        self.album        = NowPlayingInfo.filterSeasonEpisode(
            str("album", "kMRMediaRemoteNowPlayingInfoAlbum"))
        self.app          = str("clientName", "displayName", "bundleIdentifier")
        self.elapsedTime  = num("elapsedTime", "kMRMediaRemoteNowPlayingInfoElapsedTime")
        self.duration     = num("duration", "kMRMediaRemoteNowPlayingInfoDuration")
        self.playbackRate = num("playbackRate", "kMRMediaRemoteNowPlayingInfoPlaybackRate")

        var r: [String: String] = [:]
        for (k, v) in dict {
            r[k] = String(describing: v)
        }
        self.raw = r
    }

    /// Humanize a bundle identifier as a footer fallback when the player
    /// publishes no `displayName`. Netflix in particular ships zero metadata
    /// — without this fallback the footer disappears entirely the moment the
    /// AirPlay tunnel names Netflix the active client. Strategy: take the
    /// last dot-separated component (`com.netflix.Netflix` → "Netflix",
    /// `com.google.ios.youtube` → "youtube"). Returns nil for empty / nil
    /// inputs so callers can chain with `??`.
    public static func appName(fromBundle bid: String?) -> String? {
        guard let bid, !bid.isEmpty else { return nil }
        let last = bid.split(separator: ".").last.map(String.init) ?? bid
        return last.isEmpty ? bid : last
    }

    /// Drop "Season N, Episode N"-shaped values that Apple TV's catalog
    /// injects for video content. Those numbers are the catalog's internal
    /// index, not the show's real season/episode (we've seen the same
    /// "Season 8, Episode 3" string attached to two unrelated shows). Real
    /// album/artist metadata for music ("A Night at the Opera" etc.) doesn't
    /// match the pattern and is preserved.
    ///
    /// Applied to both `album` and `artist`: Amazon Prime Video puts this
    /// synthetic label in whichever field varies per title, and unlike
    /// Apple's plain two-token form it's internally redundant — an
    /// abbreviated season/episode token (or two) followed by the same
    /// episode spelled out in full: "Season 2, Ep. 5 Episode 5", "S2 E6
    /// Episode 6", etc. That trailing spelled-out token is the one worth
    /// keeping, so a 3+ token chain collapses down to just its last token
    /// instead of being dropped outright. A plain 2-token chain (no
    /// abbreviation, just "Season N, Episode N") has no redundancy to
    /// collapse — that's Apple's original unreliable-index case, so it's
    /// still dropped entirely.
    public static func filterSeasonEpisode(_ value: String?) -> String? {
        guard let value else { return nil }
        let token = #"\p{L}+\.?\s*\d+"#
        guard let regex = try? NSRegularExpression(
            pattern: "^\(token)(?:(?:,\\s*|\\s+)\(token))+$"
        ), regex.firstMatch(
            in: value, range: NSRange(value.startIndex..., in: value)
        ) != nil else {
            return value
        }
        guard let tokenRegex = try? NSRegularExpression(pattern: token) else { return nil }
        let matches = tokenRegex.matches(in: value, range: NSRange(value.startIndex..., in: value))
        guard matches.count >= 3, let last = matches.last, let range = Range(last.range, in: value) else {
            return nil
        }
        return String(value[range])
    }
}
