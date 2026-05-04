import Foundation

// MARK: - NowPlayingMerge

/// Source-agnostic snapshot of the fields we may receive in a single
/// now-playing push, as fed into `NowPlayingInfo.merging(_:lastTimestamp:anchorDate:)`.
/// Lets the AirPlay (MRPNowPlayingUpdate) and Companion (NowPlayingInfo from a
/// `_iMC` inner dict) paths share one merge implementation.
public struct NowPlayingMergeInput: Sendable {
    public var title: String?
    public var artist: String?
    public var album: String?
    /// User-facing app name (Companion-only).
    public var app: String?
    public var duration: Double?
    public var elapsedTime: Double?
    public var playbackRate: Double?
    public var playbackStateTimestamp: Double?
    /// MRP playback state enum (1=playing, 2=paused, 3=stopped, 5=seeking).
    /// AirPlay-only — used to nudge a refresh during scrubs.
    public var playbackState: Int?
    /// Companion `_iMC` raw dict, merged into `NowPlayingInfo.raw` for
    /// debugging. AirPlay path passes nil.
    public var rawCompanion: [String: String]?

    public init(
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        app: String? = nil,
        duration: Double? = nil,
        elapsedTime: Double? = nil,
        playbackRate: Double? = nil,
        playbackStateTimestamp: Double? = nil,
        playbackState: Int? = nil,
        rawCompanion: [String: String]? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.app = app
        self.duration = duration
        self.elapsedTime = elapsedTime
        self.playbackRate = playbackRate
        self.playbackStateTimestamp = playbackStateTimestamp
        self.playbackState = playbackState
        self.rawCompanion = rawCompanion
    }

    public static func from(airplay u: MRPNowPlayingUpdate) -> Self {
        Self(title: u.title, artist: u.artist, album: u.album,
             duration: u.duration, elapsedTime: u.elapsedTime,
             playbackRate: u.playbackRate,
             playbackStateTimestamp: u.playbackStateTimestamp,
             playbackState: u.playbackState)
    }

    public static func from(companion u: NowPlayingInfo) -> Self {
        Self(title: u.title, artist: u.artist, album: u.album,
             app: u.app,
             duration: u.duration, elapsedTime: u.elapsedTime,
             playbackRate: u.playbackRate,
             rawCompanion: u.raw)
    }
}

/// Side-effects reported back to the caller after a merge.
public struct NowPlayingMergeResult: Sendable {
    public let trackChanged: Bool
    public let didResume: Bool
    public let didPause: Bool
}

extension NowPlayingInfo {
    /// Pure functional merge. Apply `input` on top of `self` and return the
    /// updated `NowPlayingInfo`, a result struct, and the updated
    /// `lastTimestamp` to carry forward in the caller.
    ///
    /// - Parameters:
    ///   - input: Incoming push fields (all optional).
    ///   - lastTimestamp: The most-recent non-zero playback-state timestamp
    ///     that passed the ordering gate (owned by the caller).
    ///   - anchorDate: Wall-clock time to stamp `elapsedAnchor` when the
    ///     anchor invariant fires. Defaults to `Date()`. Tests inject a
    ///     fixed value to avoid real-clock sensitivity.
    /// - Returns: The merged `NowPlayingInfo`, a `NowPlayingMergeResult`, and
    ///   the (possibly updated) timestamp to use as `lastTimestamp` next call.
    public func merging(
        _ input: NowPlayingMergeInput,
        lastTimestamp: Double,
        anchorDate: Date = Date()
    ) -> (info: NowPlayingInfo, result: NowPlayingMergeResult, newTimestamp: Double) {
        var info = self

        // Cohort reset triggers.
        let appChanged    = (input.app    != nil) && (input.app    != info.app)
        let titleChanged  = (input.title  != nil) && (input.title  != info.title)
        let artistChanged = (input.artist != nil) && (input.artist != info.artist)
        let durationChanged: Bool = {
            guard let new = input.duration, let old = info.duration else { return false }
            return abs(new - old) > 5
        }()
        let trackChanged = appChanged || titleChanged || artistChanged || durationChanged
        if trackChanged {
            info.title        = nil
            info.artist       = nil
            info.album        = nil
            info.elapsedTime  = nil
            info.duration     = nil
            info.playbackRate = nil
            info.elapsedAnchor = nil
        }

        if let v = input.title       { info.title       = v }
        if let v = input.artist      { info.artist      = v }
        if let v = input.album       { info.album       = NowPlayingInfo.filterAlbum(v) }
        if let v = input.app         { info.app         = v }
        if let v = input.duration    { info.duration    = v }
        if let v = input.elapsedTime { info.elapsedTime = v }

        let prevRate = info.playbackRate ?? 0
        var newTimestamp = lastTimestamp
        if let v = input.playbackRate {
            // Loosened ordering gate: a push with `ts == 0` (or missing
            // entirely) is allowed through — without this, a pause arriving
            // with a reset timestamp would be silently dropped, leaving us
            // ticking forward forever (P2 issue 3ht). Strict-greater-or-equal
            // is enforced only when we have a non-zero ts to compare to.
            let ts = input.playbackStateTimestamp ?? 0
            let pass = ts == 0 || ts >= lastTimestamp
            if pass {
                if ts > 0 { newTimestamp = ts }
                // play → pause edge: bake the live-interpolated value before
                // flipping rate so liveElapsed returns the right
                // "where we paused" number after the flip.
                if v == 0, prevRate > 0, let live = info.liveElapsed(at: anchorDate) {
                    info.elapsedTime = live
                }
                info.playbackRate = v
            }
        }
        let nowRate = info.playbackRate ?? 0

        // Anchor invariant: while playing (rate > 0), `elapsedAnchor` MUST be set
        // — liveElapsed needs it to interpolate. While paused, anchor is nil.
        if nowRate == 0 {
            info.elapsedAnchor = nil
        } else if input.elapsedTime != nil || prevRate == 0 {
            info.elapsedAnchor = anchorDate
        }

        if let raw = input.rawCompanion {
            info.raw.merge(raw) { _, new in new }
        }

        return (
            info: info,
            result: NowPlayingMergeResult(
                trackChanged: trackChanged,
                didResume:    nowRate > 0 && prevRate == 0,
                didPause:     nowRate == 0 && prevRate > 0
            ),
            newTimestamp: newTimestamp
        )
    }
}
