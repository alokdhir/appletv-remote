import XCTest
@testable import AppleTVProtocol

/// Tests for `NowPlayingInfo.merging(_:lastTimestamp:anchorDate:)`.
///
/// All calls pass a fixed `anchorDate` so tests are insensitive to real-clock
/// drift and can make exact assertions on `elapsedAnchor` and `liveElapsed`.
final class NowPlayingMergeTests: XCTestCase {

    // MARK: - Helpers

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func base() -> NowPlayingInfo { NowPlayingInfo() }

    /// Shorthand: merge `input` into an empty info with zero lastTimestamp.
    private func merge(
        _ input: NowPlayingMergeInput,
        into info: NowPlayingInfo? = nil,
        lastTimestamp: Double = 0
    ) -> (info: NowPlayingInfo, result: NowPlayingMergeResult, newTimestamp: Double) {
        (info ?? NowPlayingInfo()).merging(input, lastTimestamp: lastTimestamp, anchorDate: t0)
    }

    // MARK: - Track change resets cohort

    func testTitleChangeTriggersCohortReset() {
        var initial = NowPlayingInfo()
        initial.title       = "Old Song"
        initial.artist      = "Old Artist"
        initial.album       = "Old Album"
        initial.elapsedTime = 30
        initial.duration    = 200
        initial.playbackRate = 1.0
        initial.elapsedAnchor = t0

        let input = NowPlayingMergeInput(title: "New Song")
        let (merged, result, _) = initial.merging(input, lastTimestamp: 0, anchorDate: t0)

        XCTAssertTrue(result.trackChanged)
        XCTAssertEqual(merged.title, "New Song")
        XCTAssertNil(merged.artist,      "cohort reset must clear artist")
        XCTAssertNil(merged.album,       "cohort reset must clear album")
        XCTAssertNil(merged.elapsedTime, "cohort reset must clear elapsed")
        XCTAssertNil(merged.duration,    "cohort reset must clear duration")
        XCTAssertNil(merged.playbackRate,"cohort reset must clear rate")
        XCTAssertNil(merged.elapsedAnchor)
    }

    func testArtistChangeTriggersReset() {
        var initial = NowPlayingInfo()
        initial.title  = "Song"
        initial.artist = "Artist A"

        let input = NowPlayingMergeInput(artist: "Artist B")
        let (_, result, _) = initial.merging(input, lastTimestamp: 0, anchorDate: t0)

        XCTAssertTrue(result.trackChanged)
    }

    func testAppChangeTriggersReset() {
        var initial = NowPlayingInfo()
        initial.app   = "Music"
        initial.title = "Song"

        let input = NowPlayingMergeInput(app: "Netflix")
        let (merged, result, _) = initial.merging(input, lastTimestamp: 0, anchorDate: t0)

        XCTAssertTrue(result.trackChanged)
        XCTAssertEqual(merged.app, "Netflix")
        XCTAssertNil(merged.title)
    }

    func testDurationDeltaOver5sTriggersReset() {
        var initial = NowPlayingInfo()
        initial.title    = "Song"
        initial.duration = 100.0

        let input = NowPlayingMergeInput(duration: 106.0)
        let (_, result, _) = initial.merging(input, lastTimestamp: 0, anchorDate: t0)

        XCTAssertTrue(result.trackChanged)
    }

    func testDurationDeltaUnder5sDoesNotTriggerReset() {
        var initial = NowPlayingInfo()
        initial.title    = "Song"
        initial.duration = 100.0

        let input = NowPlayingMergeInput(duration: 104.0)
        let (_, result, _) = initial.merging(input, lastTimestamp: 0, anchorDate: t0)

        XCTAssertFalse(result.trackChanged)
    }

    func testSameTitleDoesNotTriggerReset() {
        var initial = NowPlayingInfo()
        initial.title = "Same Song"

        let input = NowPlayingMergeInput(title: "Same Song", elapsedTime: 10)
        let (merged, result, _) = initial.merging(input, lastTimestamp: 0, anchorDate: t0)

        XCTAssertFalse(result.trackChanged)
        XCTAssertEqual(merged.title, "Same Song")
        XCTAssertEqual(merged.elapsedTime, 10)
    }

    // MARK: - play → pause edge bakes elapsed

    func testPlayToPauseEdgeBakesInterpolatedElapsed() {
        var initial = NowPlayingInfo()
        initial.elapsedTime   = 50.0
        initial.playbackRate  = 1.0
        initial.elapsedAnchor = t0          // anchored exactly at t0

        // Pause arrives 10 seconds after t0.
        let pauseDate = Date(timeIntervalSince1970: t0.timeIntervalSince1970 + 10)
        let input = NowPlayingMergeInput(playbackRate: 0)
        let (merged, result, _) = initial.merging(input, lastTimestamp: 0, anchorDate: pauseDate)

        XCTAssertTrue(result.didPause)
        XCTAssertFalse(result.didResume)
        // elapsed should be baked as 50 + 10*1 = 60
        XCTAssertEqual(try XCTUnwrap(merged.elapsedTime), 60.0, accuracy: 0.001)
        XCTAssertNil(merged.elapsedAnchor, "anchor cleared on pause")
        XCTAssertEqual(merged.playbackRate, 0)
    }

    func testPlayToPauseClampsToDuration() {
        var initial = NowPlayingInfo()
        initial.elapsedTime   = 195.0
        initial.duration      = 200.0
        initial.playbackRate  = 1.0
        initial.elapsedAnchor = t0

        let pauseDate = Date(timeIntervalSince1970: t0.timeIntervalSince1970 + 30)
        let input = NowPlayingMergeInput(playbackRate: 0)
        let (merged, _, _) = initial.merging(input, lastTimestamp: 0, anchorDate: pauseDate)

        XCTAssertEqual(try XCTUnwrap(merged.elapsedTime), 200.0, accuracy: 0.001, "must clamp to duration")
    }

    // MARK: - pause → play edge sets anchor

    func testPauseToPlayEdgeSetsAnchorEvenWithoutFreshElapsed() {
        var initial = NowPlayingInfo()
        initial.elapsedTime  = 42.0
        initial.playbackRate = 0.0          // currently paused
        initial.elapsedAnchor = nil

        // Resume push carries rate=1 but no elapsedTime.
        let input = NowPlayingMergeInput(playbackRate: 1.0)
        let (merged, result, _) = initial.merging(input, lastTimestamp: 0, anchorDate: t0)

        XCTAssertTrue(result.didResume)
        XCTAssertFalse(result.didPause)
        XCTAssertEqual(merged.elapsedAnchor, t0, "anchor must be set on resume")
        XCTAssertEqual(merged.elapsedTime, 42.0, "existing elapsed preserved")
        XCTAssertEqual(merged.playbackRate, 1.0)
    }

    func testPauseToPlayWithFreshElapsedAlsoSetsAnchor() {
        var initial = NowPlayingInfo()
        initial.elapsedTime  = 10.0
        initial.playbackRate = 0.0

        let input = NowPlayingMergeInput(elapsedTime: 15.0, playbackRate: 1.0)
        let (merged, result, _) = initial.merging(input, lastTimestamp: 0, anchorDate: t0)

        XCTAssertTrue(result.didResume)
        XCTAssertEqual(merged.elapsedTime, 15.0)
        XCTAssertEqual(merged.elapsedAnchor, t0)
    }

    // MARK: - ts == 0 ordering gate (regression: P2 issue 3ht)

    func testTimestampZeroPassesGateEvenWhenLastTimestampIsHigh() {
        var initial = NowPlayingInfo()
        initial.playbackRate = 1.0

        // High lastTimestamp — would normally block an older push.
        let lastTS: Double = 9999
        // Pause arrives with ts == 0 (reset/missing).
        let input = NowPlayingMergeInput(playbackRate: 0, playbackStateTimestamp: 0)
        let (merged, result, newTS) = initial.merging(input, lastTimestamp: lastTS, anchorDate: t0)

        XCTAssertTrue(result.didPause, "ts==0 push must pass the ordering gate")
        XCTAssertEqual(merged.playbackRate, 0)
        XCTAssertEqual(newTS, lastTS, "timestamp not updated when ts==0")
    }

    func testTimestampNilPassesGate() {
        var initial = NowPlayingInfo()
        initial.playbackRate = 1.0

        let lastTS: Double = 5000
        let input = NowPlayingMergeInput(playbackRate: 0)   // nil timestamp
        let (merged, result, _) = initial.merging(input, lastTimestamp: lastTS, anchorDate: t0)

        XCTAssertTrue(result.didPause)
        XCTAssertEqual(merged.playbackRate, 0)
    }

    func testOutOfOrderTimestampIsDropped() {
        var initial = NowPlayingInfo()
        initial.playbackRate = 0.0    // paused

        let lastTS: Double = 100
        // Stale resume push with ts < lastTimestamp.
        let input = NowPlayingMergeInput(playbackRate: 1.0, playbackStateTimestamp: 50)
        let (merged, result, newTS) = initial.merging(input, lastTimestamp: lastTS, anchorDate: t0)

        XCTAssertFalse(result.didResume, "stale push must be dropped")
        XCTAssertEqual(merged.playbackRate, 0.0, "rate unchanged")
        XCTAssertEqual(newTS, lastTS, "timestamp unchanged when push dropped")
    }

    func testTimestampUpdatedOnValidNonZeroPush() {
        var initial = NowPlayingInfo()
        initial.playbackRate = 1.0

        let input = NowPlayingMergeInput(playbackRate: 0, playbackStateTimestamp: 200)
        let (_, _, newTS) = initial.merging(input, lastTimestamp: 100, anchorDate: t0)

        XCTAssertEqual(newTS, 200)
    }

    // MARK: - Album filter

    func testAlbumFilterDropsSeasonEpisode() {
        XCTAssertNil(NowPlayingInfo.filterAlbum("Season 1, Episode 5"))
        XCTAssertNil(NowPlayingInfo.filterAlbum("Season 8, Episode 3"))
        XCTAssertNil(NowPlayingInfo.filterAlbum("Season 12,Episode 7"))
    }

    func testAlbumFilterKeepsRealAlbumTitle() {
        XCTAssertEqual(NowPlayingInfo.filterAlbum("A Night at the Opera"), "A Night at the Opera")
        XCTAssertEqual(NowPlayingInfo.filterAlbum("Abbey Road"), "Abbey Road")
        XCTAssertEqual(NowPlayingInfo.filterAlbum("1989"), "1989")
    }

    func testAlbumFilterNilPassthrough() {
        XCTAssertNil(NowPlayingInfo.filterAlbum(nil))
    }

    func testMergeAlbumInjectedFieldIsFiltered() {
        let input = NowPlayingMergeInput(album: "Season 3, Episode 10")
        let (merged, _, _) = merge(input)
        XCTAssertNil(merged.album, "Season/Episode album must be dropped by merge")
    }

    func testMergeRealAlbumIsPreserved() {
        let input = NowPlayingMergeInput(album: "Kind of Blue")
        let (merged, _, _) = merge(input)
        XCTAssertEqual(merged.album, "Kind of Blue")
    }

    // MARK: - liveElapsed clamps to duration

    func testLiveElapsedClampsAtDuration() {
        var info = NowPlayingInfo()
        info.elapsedTime   = 195.0
        info.duration      = 200.0
        info.playbackRate  = 1.0
        info.elapsedAnchor = t0

        let laterDate = Date(timeIntervalSince1970: t0.timeIntervalSince1970 + 100)
        let live = info.liveElapsed(at: laterDate)
        XCTAssertEqual(live, 200.0, "liveElapsed must clamp to duration")
    }

    func testLiveElapsedInterpolatesWhilePlaying() {
        var info = NowPlayingInfo()
        info.elapsedTime   = 10.0
        info.playbackRate  = 1.0
        info.elapsedAnchor = t0

        let laterDate = Date(timeIntervalSince1970: t0.timeIntervalSince1970 + 5)
        let live = info.liveElapsed(at: laterDate)
        XCTAssertEqual(live!, 15.0, accuracy: 0.001)
    }

    func testLiveElapsedReturnsFrozenValueWhenPaused() {
        var info = NowPlayingInfo()
        info.elapsedTime   = 42.0
        info.playbackRate  = 0.0
        info.elapsedAnchor = nil     // cleared on pause

        let live = info.liveElapsed(at: t0)
        XCTAssertEqual(live, 42.0)
    }

    func testLiveElapsedNilWhenNoElapsedTime() {
        let info = NowPlayingInfo()
        XCTAssertNil(info.liveElapsed(at: t0))
    }

    // MARK: - Anchor invariant

    func testAnchorSetWhenPlayingWithFreshElapsed() {
        let input = NowPlayingMergeInput(elapsedTime: 5.0, playbackRate: 1.0)
        let (merged, _, _) = merge(input)
        XCTAssertEqual(merged.elapsedAnchor, t0)
    }

    func testAnchorNilWhenPaused() {
        var initial = NowPlayingInfo()
        initial.playbackRate  = 1.0
        initial.elapsedAnchor = t0

        let input = NowPlayingMergeInput(playbackRate: 0.0)
        let (merged, _, _) = initial.merging(input, lastTimestamp: 0, anchorDate: t0)
        XCTAssertNil(merged.elapsedAnchor)
    }

    func testAnchorNotUpdatedWhenPlayingWithoutFreshElapsedOrRateChange() {
        let existingAnchor = Date(timeIntervalSince1970: t0.timeIntervalSince1970 - 60)
        var initial = NowPlayingInfo()
        initial.elapsedTime   = 60.0
        initial.playbackRate  = 1.0
        initial.elapsedAnchor = existingAnchor

        // Push only carries title update, no elapsed or rate.
        let input = NowPlayingMergeInput(title: initial.title)
        let (merged, _, _) = initial.merging(input, lastTimestamp: 0, anchorDate: t0)

        // anchor should be unchanged (still existingAnchor), not reset to t0
        XCTAssertEqual(merged.elapsedAnchor, existingAnchor)
    }

    // MARK: - Raw companion merge

    func testRawCompanionIsMerged() {
        var initial = NowPlayingInfo()
        initial.raw = ["key1": "val1"]

        let input = NowPlayingMergeInput(rawCompanion: ["key2": "val2", "key1": "updated"])
        let (merged, _, _) = initial.merging(input, lastTimestamp: 0, anchorDate: t0)

        XCTAssertEqual(merged.raw["key1"], "updated")
        XCTAssertEqual(merged.raw["key2"], "val2")
    }
}
