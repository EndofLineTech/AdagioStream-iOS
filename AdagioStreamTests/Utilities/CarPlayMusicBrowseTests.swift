// CarPlayMusicBrowseTests.swift
//
// Unit tests for the pure-logic helpers added to CarPlayTemplateManager.
//   8rg.1: formatDuration
//   8rg.2: shuffleButtonSelected / repeatButtonSelected button-state mapping
//   j7d.3: upNextRowDetail — row label logic for the Up Next queue list
//
// CarPlay UI itself can't be exercised in the simulator (no CPInterfaceController
// without a real CarPlay connection), but these static helpers are
// framework-free and fully testable here.
//
// Gated #if os(iOS) because CarPlay is iOS-only.

#if os(iOS)
import XCTest
@testable import AdagioStream

final class CarPlayMusicBrowseTests: XCTestCase {

    // MARK: - formatDuration (8rg.1)

    func testFormatDurationSeconds() {
        // Under a minute: no leading hour field
        XCTAssertEqual(CarPlayTemplateManager.formatDuration(0),  "0:00")
        XCTAssertEqual(CarPlayTemplateManager.formatDuration(1),  "0:01")
        XCTAssertEqual(CarPlayTemplateManager.formatDuration(59), "0:59")
    }

    func testFormatDurationMinutes() {
        XCTAssertEqual(CarPlayTemplateManager.formatDuration(60),  "1:00")
        XCTAssertEqual(CarPlayTemplateManager.formatDuration(61),  "1:01")
        XCTAssertEqual(CarPlayTemplateManager.formatDuration(90),  "1:30")
        XCTAssertEqual(CarPlayTemplateManager.formatDuration(3599), "59:59")
    }

    func testFormatDurationHours() {
        XCTAssertEqual(CarPlayTemplateManager.formatDuration(3600), "1:00:00")
        XCTAssertEqual(CarPlayTemplateManager.formatDuration(3661), "1:01:01")
        XCTAssertEqual(CarPlayTemplateManager.formatDuration(7323), "2:02:03")
    }

    func testFormatDurationTypicalTrackLength() {
        // 3 min 45 sec = 225 seconds
        XCTAssertEqual(CarPlayTemplateManager.formatDuration(225), "3:45")
        // 4 min 02 sec = 242 seconds
        XCTAssertEqual(CarPlayTemplateManager.formatDuration(242), "4:02")
    }

    // MARK: - shuffleButtonSelected (8rg.2)

    func testShuffleButtonSelectedWhenEnabled() {
        // The CarPlay shuffle button should appear highlighted when shuffle is on.
        XCTAssertTrue(
            CarPlayTemplateManager.shuffleButtonSelected(shuffleEnabled: true),
            "Shuffle button should be selected when shuffle is enabled"
        )
    }

    func testShuffleButtonNotSelectedWhenDisabled() {
        // The CarPlay shuffle button should NOT appear highlighted when shuffle is off.
        XCTAssertFalse(
            CarPlayTemplateManager.shuffleButtonSelected(shuffleEnabled: false),
            "Shuffle button should not be selected when shuffle is disabled"
        )
    }

    // MARK: - repeatButtonSelected (8rg.2)

    func testRepeatButtonNotSelectedWhenOff() {
        // .off → no repeat active → button not highlighted.
        XCTAssertFalse(
            CarPlayTemplateManager.repeatButtonSelected(repeatMode: .off),
            "Repeat button should not be selected when repeatMode is .off"
        )
    }

    func testRepeatButtonSelectedWhenAll() {
        // .all → repeat active → button highlighted.
        XCTAssertTrue(
            CarPlayTemplateManager.repeatButtonSelected(repeatMode: .all),
            "Repeat button should be selected when repeatMode is .all"
        )
    }

    func testRepeatButtonSelectedWhenOne() {
        // .one → repeat active → button highlighted.
        XCTAssertTrue(
            CarPlayTemplateManager.repeatButtonSelected(repeatMode: .one),
            "Repeat button should be selected when repeatMode is .one"
        )
    }

    func testRepeatButtonCycleOrder() {
        // Verify the full cycle: .off → .all → .one → .off
        // (the mapping used by cycleRepeatMode()).
        XCTAssertEqual(RepeatMode.off.next, .all)
        XCTAssertEqual(RepeatMode.all.next, .one)
        XCTAssertEqual(RepeatMode.one.next, .off)
    }

    // MARK: - upNextRowDetail (j7d.3)

    func testUpNextRowDetailCurrentTrack() {
        // The currently-playing track shows "Now Playing" regardless of duration.
        XCTAssertEqual(
            CarPlayTemplateManager.upNextRowDetail(index: 2, currentIndex: 2, duration: 225),
            "Now Playing",
            "Currently-playing track should show 'Now Playing'"
        )
        XCTAssertEqual(
            CarPlayTemplateManager.upNextRowDetail(index: 0, currentIndex: 0, duration: nil),
            "Now Playing",
            "Currently-playing track with no duration should still show 'Now Playing'"
        )
    }

    func testUpNextRowDetailOtherTrackWithDuration() {
        // A non-playing track with a known duration shows the formatted duration.
        XCTAssertEqual(
            CarPlayTemplateManager.upNextRowDetail(index: 1, currentIndex: 0, duration: 225),
            "3:45",
            "Non-playing track with duration should show formatted duration"
        )
        XCTAssertEqual(
            CarPlayTemplateManager.upNextRowDetail(index: 3, currentIndex: 0, duration: 3661),
            "1:01:01",
            "Non-playing track with hour-range duration should format correctly"
        )
    }

    func testUpNextRowDetailOtherTrackNoDuration() {
        // A non-playing track with no duration returns nil.
        XCTAssertNil(
            CarPlayTemplateManager.upNextRowDetail(index: 1, currentIndex: 0, duration: nil),
            "Non-playing track with no duration should return nil detail"
        )
    }

    func testUpNextRowDetailNoCurrentIndex() {
        // When currentIndex is nil (queue not fully initialized), no "Now Playing" label.
        XCTAssertEqual(
            CarPlayTemplateManager.upNextRowDetail(index: 0, currentIndex: nil, duration: 60),
            "1:00",
            "With no currentIndex, row shows duration"
        )
        XCTAssertNil(
            CarPlayTemplateManager.upNextRowDetail(index: 0, currentIndex: nil, duration: nil),
            "With no currentIndex and no duration, row detail is nil"
        )
    }

    // MARK: - audiobookRowDetail (ciu.1)

    private func makeBook(author: String?, progress: Double, isFinished: Bool) -> Audiobook {
        Audiobook(
            id: "b1", libraryItemId: "b1", libraryId: "lib1", title: "A Book",
            author: author, progress: progress, isFinished: isFinished, updatedAt: 0
        )
    }

    func testAudiobookRowDetailAuthorAndProgress() {
        let book = makeBook(author: "Ursula K. Le Guin", progress: 0.42, isFinished: false)
        XCTAssertEqual(
            CarPlayTemplateManager.audiobookRowDetail(book),
            "Ursula K. Le Guin · 42% listened"
        )
    }

    func testAudiobookRowDetailFinishedWins() {
        // Finished takes precedence over a progress percentage.
        let book = makeBook(author: "Author", progress: 0.9, isFinished: true)
        XCTAssertEqual(CarPlayTemplateManager.audiobookRowDetail(book), "Author · Finished")
    }

    func testAudiobookRowDetailAuthorOnlyWhenUnstarted() {
        let book = makeBook(author: "Author", progress: 0, isFinished: false)
        XCTAssertEqual(CarPlayTemplateManager.audiobookRowDetail(book), "Author")
    }

    func testAudiobookRowDetailProgressOnlyWhenNoAuthor() {
        let book = makeBook(author: nil, progress: 0.5, isFinished: false)
        XCTAssertEqual(CarPlayTemplateManager.audiobookRowDetail(book), "50% listened")
    }

    func testAudiobookRowDetailEmptyAuthorTreatedAsNil() {
        let book = makeBook(author: "", progress: 0, isFinished: false)
        XCTAssertNil(CarPlayTemplateManager.audiobookRowDetail(book))
    }

    // MARK: - podcastEpisodeRowDetail (hky.1)

    private func makeEpisode(pubDate: String?, duration: Double?) -> ABSEpisodeDTO {
        var fields = ["\"id\": \"e1\"", "\"title\": \"An Episode\""]
        if let pubDate { fields.append("\"pubDate\": \"\(pubDate)\"") }
        if let duration { fields.append("\"duration\": \(duration)") }
        let json = "{\(fields.joined(separator: ","))}"
        return try! JSONDecoder().decode(ABSEpisodeDTO.self, from: Data(json.utf8))
    }

    // pubDate is parsed as GMT then rendered via the local-timezone
    // DateFormatter, so a midnight-GMT fixture could shift to the prior day
    // in western-hemisphere timezones. Noon-GMT is safe across every real
    // UTC offset (-12...+14).
    func testPodcastEpisodeRowDetailDateAndDuration() {
        let episode = makeEpisode(pubDate: "Mon, 01 Jan 2024 12:00:00 GMT", duration: 90)
        XCTAssertEqual(
            CarPlayTemplateManager.podcastEpisodeRowDetail(episode),
            "Jan 1, 2024 · 1m"
        )
    }

    func testPodcastEpisodeRowDetailDateOnlyWhenNoDuration() {
        let episode = makeEpisode(pubDate: "Mon, 01 Jan 2024 12:00:00 GMT", duration: nil)
        XCTAssertEqual(CarPlayTemplateManager.podcastEpisodeRowDetail(episode), "Jan 1, 2024")
    }

    func testPodcastEpisodeRowDetailDurationOnlyWhenNoDate() {
        let episode = makeEpisode(pubDate: nil, duration: 90)
        XCTAssertEqual(CarPlayTemplateManager.podcastEpisodeRowDetail(episode), "1m")
    }

    func testPodcastEpisodeRowDetailNilWhenNeither() {
        let episode = makeEpisode(pubDate: nil, duration: nil)
        XCTAssertNil(CarPlayTemplateManager.podcastEpisodeRowDetail(episode))
    }

    // MARK: - nowPlayingButtonKind (uxa.1)
    //
    // This is the routing decision behind the bug: audiobook/podcast playback
    // fell into the radio branch (no third case existed), rendering a
    // favorite-star button whose handler guards on currentChannel (nil for
    // books) and silently no-ops on every tap.

    func testNowPlayingButtonKindForLibrary() {
        let tracks = [Track(id: "t1", albumId: "a1", artistId: "ar1", title: "One", updatedAt: 0)]
        let source = PlaybackSource.library(queue: tracks, index: 0)
        XCTAssertEqual(CarPlayTemplateManager.nowPlayingButtonKind(for: source), .library)
    }

    func testNowPlayingButtonKindForRadio() {
        let channel = Channel(id: "c1", name: "KEXP", streamURL: URL(string: "https://example.com")!)
        let source = PlaybackSource.radio(channel)
        XCTAssertEqual(CarPlayTemplateManager.nowPlayingButtonKind(for: source), .radio)
    }

    func testNowPlayingButtonKindForNilSourceIsRadio() {
        // Matches historical behavior: no source captured yet defaults to radio buttons.
        XCTAssertEqual(CarPlayTemplateManager.nowPlayingButtonKind(for: nil), .radio)
    }

    func testNowPlayingButtonKindForAudiobook() {
        let book = Audiobook(id: "b1", libraryItemId: "b1", libraryId: "lib1", title: "A Book", updatedAt: 0)
        let source = PlaybackSource.audiobook(book)
        XCTAssertEqual(CarPlayTemplateManager.nowPlayingButtonKind(for: source), .audiobook)
    }

    // MARK: - rootPlaceholderState (uxa.2)
    //
    // The CarPlay root's empty-channel-list placeholder previously showed
    // "No Channels — Add an account on your phone" identically whether no
    // provider existed, the provider was still loading, or the load failed.

    func testRootPlaceholderStateUnconfiguredWhenNoProviders() {
        XCTAssertEqual(
            CarPlayTemplateManager.rootPlaceholderState(providersEmpty: true, isLoading: false, hasError: false),
            .unconfigured
        )
        // Providers empty always wins, even if isLoading/hasError happen to be true too.
        XCTAssertEqual(
            CarPlayTemplateManager.rootPlaceholderState(providersEmpty: true, isLoading: true, hasError: true),
            .unconfigured
        )
    }

    func testRootPlaceholderStateLoadingWhenConfiguredAndLoading() {
        XCTAssertEqual(
            CarPlayTemplateManager.rootPlaceholderState(providersEmpty: false, isLoading: true, hasError: false),
            .loading
        )
        // Loading wins over a stale error from a prior attempt.
        XCTAssertEqual(
            CarPlayTemplateManager.rootPlaceholderState(providersEmpty: false, isLoading: true, hasError: true),
            .loading
        )
    }

    func testRootPlaceholderStateFailedWhenConfiguredNotLoadingStillEmptyWithError() {
        XCTAssertEqual(
            CarPlayTemplateManager.rootPlaceholderState(providersEmpty: false, isLoading: false, hasError: true),
            .failed
        )
    }

    /// uxa kickback (finding 3): configured + loaded + zero channels + no
    /// error (e.g. every group disabled) must NOT read as "failed" — that
    /// told a working setup to "check your connection".
    func testRootPlaceholderStateEmptyWhenConfiguredNotLoadingNoError() {
        XCTAssertEqual(
            CarPlayTemplateManager.rootPlaceholderState(providersEmpty: false, isLoading: false, hasError: false),
            .empty
        )
    }

    // MARK: - shouldShowMusicSetupHint (beads_mobilemusic-iqt)
    //
    // The CarPlay Music section shows a "Set Up on iPhone" discoverability
    // row instead of hiding Music entirely when no Subsonic provider is
    // configured — but only when the root has other real content. When
    // nothing at all is configured, the uxa.2 unconfigured placeholder
    // already prompts setup; showing both would be two setup prompts for
    // one blank state.

    func testShouldShowMusicSetupHintWhenChannelsPresent() {
        XCTAssertTrue(
            CarPlayTemplateManager.shouldShowMusicSetupHint(hasChannels: true, hasAudiobooks: false, hasPodcasts: false)
        )
    }

    func testShouldShowMusicSetupHintWhenAudiobooksPresent() {
        XCTAssertTrue(
            CarPlayTemplateManager.shouldShowMusicSetupHint(hasChannels: false, hasAudiobooks: true, hasPodcasts: false)
        )
    }

    func testShouldShowMusicSetupHintWhenPodcastsPresent() {
        XCTAssertTrue(
            CarPlayTemplateManager.shouldShowMusicSetupHint(hasChannels: false, hasAudiobooks: false, hasPodcasts: true)
        )
    }

    /// Nothing configured at all — the uxa.2 placeholder handles discoverability
    /// instead, so the hint must not double up on it.
    func testShouldNotShowMusicSetupHintWhenNothingConfigured() {
        XCTAssertFalse(
            CarPlayTemplateManager.shouldShowMusicSetupHint(hasChannels: false, hasAudiobooks: false, hasPodcasts: false)
        )
    }

    func testRootPlaceholderCopy() {
        XCTAssertEqual(CarPlayTemplateManager.RootPlaceholder.unconfigured.text, "No Channels")
        XCTAssertEqual(CarPlayTemplateManager.RootPlaceholder.unconfigured.detailText, "Add an account on your phone")
        XCTAssertEqual(CarPlayTemplateManager.RootPlaceholder.loading.text, "Loading channels…")
        XCTAssertNil(CarPlayTemplateManager.RootPlaceholder.loading.detailText)
        XCTAssertEqual(CarPlayTemplateManager.RootPlaceholder.failed.text, "Couldn't load channels")
        XCTAssertEqual(CarPlayTemplateManager.RootPlaceholder.failed.detailText, "Check your connection")
        XCTAssertEqual(CarPlayTemplateManager.RootPlaceholder.empty.text, "No Channels Available")
        XCTAssertNil(CarPlayTemplateManager.RootPlaceholder.empty.detailText)
    }

    // MARK: - letterIndexBuckets (uxa kickback finding 5)
    //
    // Pure, framework-free truth-table tests for the grouping/sort-order
    // decision behind letterIndexedSections. Operates on indices into the
    // input name array rather than CPListItem so no CarPlay type needs to be
    // constructed.

    func testLetterIndexBucketsEmptyInput() {
        let buckets = CarPlayTemplateManager.letterIndexBuckets(for: [], sortPrefixes: [])
        XCTAssertTrue(buckets.isEmpty)
    }

    func testLetterIndexBucketsNonLetterLeadingNameGoesToHashBucket() {
        let buckets = CarPlayTemplateManager.letterIndexBuckets(for: ["1970s Hits", "Zoo"], sortPrefixes: [])
        XCTAssertEqual(buckets.map(\.letter), ["#", "Z"], "\"#\" sorts before letters")
        XCTAssertEqual(buckets[0].indices, [0])
        XCTAssertEqual(buckets[1].indices, [1])
    }

    func testLetterIndexBucketsDiacriticLeadingNameGetsOwnBucket() {
        // Pins current behavior: diacritics are NOT folded into the base
        // letter's bucket (no Unicode normalization applied).
        let buckets = CarPlayTemplateManager.letterIndexBuckets(for: ["Étude", "Eagle"], sortPrefixes: [])
        let letters = Set(buckets.map(\.letter))
        XCTAssertTrue(letters.contains("É"), "Diacritic-leading name must bucket under its own accented letter")
        XCTAssertTrue(letters.contains("E"))
        XCTAssertEqual(buckets.count, 2, "É and E must NOT collapse into one bucket")
    }

    func testLetterIndexBucketsMultiLetterGroupingAndSortOrder() {
        let names = ["Bravo", "Alpha", "Charlie", "Beta", "Apple"]
        let buckets = CarPlayTemplateManager.letterIndexBuckets(for: names, sortPrefixes: [])
        XCTAssertEqual(buckets.map(\.letter), ["A", "B", "C"], "Buckets must sort A→Z with no \"#\" present")
        XCTAssertEqual(Set(buckets[0].indices), Set([1, 4]), "\"A\" bucket must contain Alpha (1) and Apple (4)")
        XCTAssertEqual(Set(buckets[1].indices), Set([0, 3]), "\"B\" bucket must contain Bravo (0) and Beta (3)")
        XCTAssertEqual(buckets[2].indices, [2], "\"C\" bucket must contain Charlie (2)")
    }

    func testLetterIndexBucketsStripsSortPrefixes() {
        // "The Beatles" sorts under "B" when "The " is a configured prefix.
        let buckets = CarPlayTemplateManager.letterIndexBuckets(for: ["The Beatles", "Abba"], sortPrefixes: ["The "])
        XCTAssertEqual(buckets.map(\.letter), ["A", "B"])
        XCTAssertEqual(buckets[1].indices, [0])
    }
}
#endif
