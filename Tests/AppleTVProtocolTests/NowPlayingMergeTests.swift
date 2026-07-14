import XCTest
@testable import AppleTVProtocol

/// Tests for `NowPlayingInfo.merging(_:lastTimestamp:anchorDate:)`.
///
/// All calls pass a fixed `anchorDate` so tests are insensitive to real-clock
/// drift and can make exact assertions on `elapsedAnchor` and `liveElapsed`.
final class NowPlayingMergeTests: XCTestCase {

    // MARK: - Helpers

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// Shorthand: merge `input` into an empty info with zero lastTimestamp.
    private func merge(
        _ input: NowPlayingMergeInput,
        into info: NowPlayingInfo? = nil,
        lastTimestamp: Double = 0
    ) -> NowPlayingMergeOutput {
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
        let out = initial.merging(input, lastTimestamp: 0, anchorDate: t0)

        XCTAssertTrue(out.result.trackChanged)
        XCTAssertEqual(out.info.title, "New Song")
        XCTAssertNil(out.info.artist,      "cohort reset must clear artist")
        XCTAssertNil(out.info.album,       "cohort reset must clear album")
        XCTAssertNil(out.info.elapsedTime, "cohort reset must clear elapsed")
        XCTAssertNil(out.info.duration,    "cohort reset must clear duration")
        XCTAssertNil(out.info.playbackRate,"cohort reset must clear rate")
        XCTAssertNil(out.info.elapsedAnchor)
    }

    func testArtistChangeTriggersReset() {
        var initial = NowPlayingInfo()
        initial.title  = "Song"
        initial.artist = "Artist A"

        let input = NowPlayingMergeInput(artist: "Artist B")
        let out = initial.merging(input, lastTimestamp: 0, anchorDate: t0)

        XCTAssertTrue(out.result.trackChanged)
    }

    func testAppChangeTriggersReset() {
        var initial = NowPlayingInfo()
        initial.app   = "Music"
        initial.title = "Song"

        let input = NowPlayingMergeInput(app: "Netflix")
        let out = initial.merging(input, lastTimestamp: 0, anchorDate: t0)

        XCTAssertTrue(out.result.trackChanged)
        XCTAssertEqual(out.info.app, "Netflix")
        XCTAssertNil(out.info.title)
    }

    func testDurationDeltaOver5sTriggersReset() {
        var initial = NowPlayingInfo()
        initial.title    = "Song"
        initial.duration = 100.0

        let input = NowPlayingMergeInput(duration: 106.0)
        let out = initial.merging(input, lastTimestamp: 0, anchorDate: t0)

        XCTAssertTrue(out.result.trackChanged)
    }

    func testDurationDeltaUnder5sDoesNotTriggerReset() {
        var initial = NowPlayingInfo()
        initial.title    = "Song"
        initial.duration = 100.0

        let input = NowPlayingMergeInput(duration: 104.0)
        let out = initial.merging(input, lastTimestamp: 0, anchorDate: t0)

        XCTAssertFalse(out.result.trackChanged)
    }

    func testSameTitleDoesNotTriggerReset() {
        var initial = NowPlayingInfo()
        initial.title = "Same Song"

        let input = NowPlayingMergeInput(title: "Same Song", elapsedTime: 10)
        let out = initial.merging(input, lastTimestamp: 0, anchorDate: t0)

        XCTAssertFalse(out.result.trackChanged)
        XCTAssertEqual(out.info.title, "Same Song")
        XCTAssertEqual(out.info.elapsedTime, 10)
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
        let out = initial.merging(input, lastTimestamp: 0, anchorDate: pauseDate)

        XCTAssertTrue(out.result.didPause)
        XCTAssertFalse(out.result.didResume)
        // elapsed should be baked as 50 + 10*1 = 60
        XCTAssertEqual(try XCTUnwrap(out.info.elapsedTime), 60.0, accuracy: 0.001)
        XCTAssertNil(out.info.elapsedAnchor, "anchor cleared on pause")
        XCTAssertEqual(out.info.playbackRate, 0)
    }

    func testPlayToPauseClampsToDuration() {
        var initial = NowPlayingInfo()
        initial.elapsedTime   = 195.0
        initial.duration      = 200.0
        initial.playbackRate  = 1.0
        initial.elapsedAnchor = t0

        let pauseDate = Date(timeIntervalSince1970: t0.timeIntervalSince1970 + 30)
        let input = NowPlayingMergeInput(playbackRate: 0)
        let out = initial.merging(input, lastTimestamp: 0, anchorDate: pauseDate)

        XCTAssertEqual(try XCTUnwrap(out.info.elapsedTime), 200.0, accuracy: 0.001, "must clamp to duration")
    }

    // MARK: - pause → play edge sets anchor

    func testPauseToPlayEdgeSetsAnchorEvenWithoutFreshElapsed() {
        var initial = NowPlayingInfo()
        initial.elapsedTime  = 42.0
        initial.playbackRate = 0.0          // currently paused
        initial.elapsedAnchor = nil

        // Resume push carries rate=1 but no elapsedTime.
        let input = NowPlayingMergeInput(playbackRate: 1.0)
        let out = initial.merging(input, lastTimestamp: 0, anchorDate: t0)

        XCTAssertTrue(out.result.didResume)
        XCTAssertFalse(out.result.didPause)
        XCTAssertEqual(out.info.elapsedAnchor, t0, "anchor must be set on resume")
        XCTAssertEqual(out.info.elapsedTime, 42.0, "existing elapsed preserved")
        XCTAssertEqual(out.info.playbackRate, 1.0)
    }

    func testPauseToPlayWithFreshElapsedAlsoSetsAnchor() {
        var initial = NowPlayingInfo()
        initial.elapsedTime  = 10.0
        initial.playbackRate = 0.0

        let input = NowPlayingMergeInput(elapsedTime: 15.0, playbackRate: 1.0)
        let out = initial.merging(input, lastTimestamp: 0, anchorDate: t0)

        XCTAssertTrue(out.result.didResume)
        XCTAssertEqual(out.info.elapsedTime, 15.0)
        XCTAssertEqual(out.info.elapsedAnchor, t0)
    }

    // MARK: - ts == 0 ordering gate (regression: P2 issue 3ht)

    func testTimestampZeroPassesGateEvenWhenLastTimestampIsHigh() {
        var initial = NowPlayingInfo()
        initial.playbackRate = 1.0

        // High lastTimestamp — would normally block an older push.
        let lastTS: Double = 9999
        // Pause arrives with ts == 0 (reset/missing).
        let input = NowPlayingMergeInput(playbackRate: 0, playbackStateTimestamp: 0)
        let out = initial.merging(input, lastTimestamp: lastTS, anchorDate: t0)

        XCTAssertTrue(out.result.didPause, "ts==0 push must pass the ordering gate")
        XCTAssertEqual(out.info.playbackRate, 0)
        XCTAssertEqual(out.newTimestamp, lastTS, "timestamp not updated when ts==0")
    }

    func testTimestampNilPassesGate() {
        var initial = NowPlayingInfo()
        initial.playbackRate = 1.0

        let lastTS: Double = 5000
        let input = NowPlayingMergeInput(playbackRate: 0)   // nil timestamp
        let out = initial.merging(input, lastTimestamp: lastTS, anchorDate: t0)

        XCTAssertTrue(out.result.didPause)
        XCTAssertEqual(out.info.playbackRate, 0)
    }

    func testOutOfOrderTimestampIsDropped() {
        var initial = NowPlayingInfo()
        initial.playbackRate = 0.0    // paused

        let lastTS: Double = 100
        // Stale resume push with ts < lastTimestamp.
        let input = NowPlayingMergeInput(playbackRate: 1.0, playbackStateTimestamp: 50)
        let out = initial.merging(input, lastTimestamp: lastTS, anchorDate: t0)

        XCTAssertFalse(out.result.didResume, "stale push must be dropped")
        XCTAssertEqual(out.info.playbackRate, 0.0, "rate unchanged")
        XCTAssertEqual(out.newTimestamp, lastTS, "timestamp unchanged when push dropped")
    }

    func testTimestampUpdatedOnValidNonZeroPush() {
        var initial = NowPlayingInfo()
        initial.playbackRate = 1.0

        let input = NowPlayingMergeInput(playbackRate: 0, playbackStateTimestamp: 200)
        let out = initial.merging(input, lastTimestamp: 100, anchorDate: t0)

        XCTAssertEqual(out.newTimestamp, 200)
    }

    // MARK: - Album filter

    func testAlbumFilterDropsSeasonEpisode() {
        XCTAssertNil(NowPlayingInfo.filterAlbum("Season 1, Episode 5"))
        XCTAssertNil(NowPlayingInfo.filterAlbum("Season 8, Episode 3"))
        XCTAssertNil(NowPlayingInfo.filterAlbum("Season 12,Episode 7"))
    }

    func testAlbumFilterDropsAmazonAbbreviatedAndFullEpisodeLabel() {
        XCTAssertNil(NowPlayingInfo.filterAlbum("Season 2, Ep. 5 Episode 5"))
        XCTAssertNil(NowPlayingInfo.filterAlbum("Season 1, Ep. 12 Episode 12"))
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
        let out = merge(input)
        XCTAssertNil(out.info.album, "Season/Episode album must be dropped by merge")
    }

    func testMergeRealAlbumIsPreserved() {
        let input = NowPlayingMergeInput(album: "Kind of Blue")
        let out = merge(input)
        XCTAssertEqual(out.info.album, "Kind of Blue")
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
        let out = merge(input)
        XCTAssertEqual(out.info.elapsedAnchor, t0)
    }

    func testAnchorNilWhenPaused() {
        var initial = NowPlayingInfo()
        initial.playbackRate  = 1.0
        initial.elapsedAnchor = t0

        let input = NowPlayingMergeInput(playbackRate: 0.0)
        let out = initial.merging(input, lastTimestamp: 0, anchorDate: t0)
        XCTAssertNil(out.info.elapsedAnchor)
    }

    func testAnchorNotUpdatedWhenPlayingWithoutFreshElapsedOrRateChange() {
        let existingAnchor = Date(timeIntervalSince1970: t0.timeIntervalSince1970 - 60)
        var initial = NowPlayingInfo()
        initial.elapsedTime   = 60.0
        initial.playbackRate  = 1.0
        initial.elapsedAnchor = existingAnchor

        // Empty push (no rate, no elapsed) must not move the anchor — neither
        // branch of the invariant should fire because nowRate != 0 AND the
        // input carried neither elapsedTime nor a rate change.
        let input = NowPlayingMergeInput()
        let out = initial.merging(input, lastTimestamp: 0, anchorDate: t0)

        // anchor should be unchanged (still existingAnchor), not reset to t0
        XCTAssertEqual(out.info.elapsedAnchor, existingAnchor)
    }

    // MARK: - Raw companion merge

    func testRawCompanionIsMerged() {
        var initial = NowPlayingInfo()
        initial.raw = ["key1": "val1"]

        let input = NowPlayingMergeInput(rawCompanion: ["key2": "val2", "key1": "updated"])
        let out = initial.merging(input, lastTimestamp: 0, anchorDate: t0)

        XCTAssertEqual(out.info.raw["key1"], "updated")
        XCTAssertEqual(out.info.raw["key2"], "val2")
    }

    // MARK: - AirPlay app fallback (Netflix-style "no displayName at all")

    func testAirplayInputUsesDisplayNameWhenPresent() {
        var u = MRPNowPlayingUpdate()
        u.displayName = "Netflix"
        u.bundleIdentifier = "com.netflix.Netflix"
        let input = NowPlayingMergeInput.from(airplay: u)
        XCTAssertEqual(input.app, "Netflix")
    }

    func testAirplayInputFallsBackToBundleLastComponent() {
        var u = MRPNowPlayingUpdate()
        u.bundleIdentifier = "com.netflix.Netflix"
        let input = NowPlayingMergeInput.from(airplay: u)
        XCTAssertEqual(input.app, "Netflix",
            "displayName is nil — must fall back to the bundle id's last component so the footer still shows the app name")
    }

    func testAirplayInputAppIsNilWhenNoIdentifierAtAll() {
        let u = MRPNowPlayingUpdate()
        let input = NowPlayingMergeInput.from(airplay: u)
        XCTAssertNil(input.app)
    }

    func testAppNameFromBundleHelper() {
        XCTAssertEqual(NowPlayingInfo.appName(fromBundle: "com.netflix.Netflix"), "Netflix")
        XCTAssertEqual(NowPlayingInfo.appName(fromBundle: "com.apple.TVAppleTVApp"), "TVAppleTVApp")
        XCTAssertEqual(NowPlayingInfo.appName(fromBundle: "Netflix"), "Netflix")
        XCTAssertNil(NowPlayingInfo.appName(fromBundle: nil))
        XCTAssertNil(NowPlayingInfo.appName(fromBundle: ""))
    }
}
