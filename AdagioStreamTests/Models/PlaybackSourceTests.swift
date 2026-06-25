import XCTest
@testable import AdagioStream

// MARK: - NowPlayingItem conformance tests

final class PlaybackSourceTests: XCTestCase {

    // MARK: - Helpers

    private func makeChannel() -> Channel {
        Channel(
            id: "ch-1",
            name: "KEXP 90.3",
            streamURL: URL(string: "https://kexp.example.com/stream")!,
            logoURL: URL(string: "https://kexp.example.com/logo.png"),
            group: "Community Radio",
            epgChannelID: nil,
            isFavorite: false,
            providerName: "My Provider",
            isCustomPlaylist: false
        )
    }

    private func makeTrack(id: String = "trk-1", title: String = "Pyramid Song", artistId: String = "art-radiohead", artist: String? = nil) -> Track {
        Track(
            id: id,
            albumId: "alb-1",
            artistId: artistId,
            title: title,
            artist: artist,
            updatedAt: 1_700_000_000
        )
    }

    // MARK: - Channel: NowPlayingItem conformance

    func testChannelDisplayTitle() {
        let ch = makeChannel()
        XCTAssertEqual(ch.displayTitle, "KEXP 90.3")
    }

    func testChannelDisplaySubtitle() {
        let ch = makeChannel()
        XCTAssertEqual(ch.displaySubtitle, "Community Radio")
    }

    func testChannelDisplaySubtitleNilWhenGroupEmpty() {
        let ch = Channel(
            id: "ch-2",
            name: "Test Station",
            streamURL: URL(string: "https://example.com")!,
            group: ""
        )
        XCTAssertNil(ch.displaySubtitle)
    }

    func testChannelArtworkURL() {
        let ch = makeChannel()
        XCTAssertEqual(ch.artworkURL?.absoluteString, "https://kexp.example.com/logo.png")
    }

    func testChannelArtworkURLNilWhenNoLogo() {
        let ch = Channel(
            id: "ch-3",
            name: "No Logo",
            streamURL: URL(string: "https://example.com")!
        )
        XCTAssertNil(ch.artworkURL)
    }

    func testChannelIsLiveStream() {
        let ch = makeChannel()
        XCTAssertTrue(ch.isLiveStream)
    }

    // MARK: - Track: NowPlayingItem conformance

    func testTrackDisplayTitle() {
        let trk = makeTrack(title: "Pyramid Song")
        XCTAssertEqual(trk.displayTitle, "Pyramid Song")
    }

    func testTrackDisplaySubtitleIsArtistName() {
        // c2o: the denormalised artist name is the subtitle.
        let trk = makeTrack(artistId: "art-radiohead", artist: "Radiohead")
        XCTAssertEqual(trk.displaySubtitle, "Radiohead")
    }

    func testTrackDisplaySubtitleNilWhenNoArtistName() {
        // No denormalised name (e.g. a row cached before the c2o column existed):
        // the raw artistId must never leak into the UI (bug hzl).
        let trk = makeTrack(artistId: "art-radiohead", artist: nil)
        XCTAssertNil(trk.displaySubtitle)
    }

    func testTrackDisplaySubtitleNilWhenArtistIdEmpty() {
        let trk = Track(
            id: "trk-2",
            albumId: "alb-1",
            artistId: "",
            title: "Silent",
            updatedAt: 1_700_000_000
        )
        XCTAssertNil(trk.displaySubtitle)
    }

    func testTrackArtworkURLIsNilPhase1() {
        let trk = makeTrack()
        // Phase 1: no cover-art URL (requires base URL resolution in d6q.2)
        XCTAssertNil(trk.artworkURL)
    }

    func testTrackIsNotLiveStream() {
        let trk = makeTrack()
        XCTAssertFalse(trk.isLiveStream)
    }

    // MARK: - PlaybackSource.radio

    func testRadioSourceCurrentItemIsChannel() {
        let ch = makeChannel()
        let source = PlaybackSource.radio(ch)
        let item = source.currentItem
        XCTAssertEqual(item.displayTitle, "KEXP 90.3")
        XCTAssertTrue(item.isLiveStream)
    }

    // MARK: - PlaybackSource.library

    func testLibrarySourceCurrentItemIsTrackAtIndex() {
        let tracks = [
            makeTrack(id: "trk-1", title: "Track One"),
            makeTrack(id: "trk-2", title: "Track Two"),
            makeTrack(id: "trk-3", title: "Track Three"),
        ]
        let source = PlaybackSource.library(queue: tracks, index: 1)
        let item = source.currentItem
        XCTAssertEqual(item.displayTitle, "Track Two")
        XCTAssertFalse(item.isLiveStream)
    }

    func testLibrarySourceFirstTrack() {
        let tracks = [
            makeTrack(id: "trk-1", title: "First"),
            makeTrack(id: "trk-2", title: "Second"),
        ]
        let source = PlaybackSource.library(queue: tracks, index: 0)
        XCTAssertEqual(source.currentItem.displayTitle, "First")
    }

    // MARK: - Track NowPlayingItem rendering (d6q.2)

    /// Track.displayTitle is the track title — the primary field shown in mini-player / now-playing.
    func testTrackDisplayTitleIsTitle() {
        let trk = makeTrack(title: "Everything in Its Right Place")
        XCTAssertEqual(trk.displayTitle, "Everything in Its Right Place")
    }

    /// bug hzl: Track.displaySubtitle never exposes the opaque artistId — only
    /// the denormalised artist name (c2o) or nil.
    func testTrackDisplaySubtitleIsNilWhenOnlyArtistIdPresent() {
        let trk = makeTrack(artistId: "ar-radiohead", artist: nil)
        XCTAssertNil(trk.displaySubtitle)
    }

    /// Track without an artistId produces nil subtitle (no empty string shown in UI).
    func testTrackDisplaySubtitleNilForEmptyArtistId() {
        let trk = Track(
            id: "t-empty",
            albumId: "al-1",
            artistId: "",
            title: "Untitled",
            updatedAt: 0
        )
        XCTAssertNil(trk.displaySubtitle)
    }

    /// Track.artworkURL is nil on the model itself; the play-path resolves the URL
    /// and sets it via MPNowPlayingInfoCenter rather than storing it on the Track.
    func testTrackArtworkURLIsNilOnModel() {
        let trk = makeTrack()
        XCTAssertNil(trk.artworkURL,
            "artworkURL is resolved at play-time via NavidromeAPI.coverArtURL; nil on the model is expected")
    }

    /// Track is never a live stream — required so the mini-player skips the LIVE indicator.
    func testTrackIsNotLiveStreamForMiniPlayerRouting() {
        let trk = makeTrack()
        XCTAssertFalse(trk.isLiveStream)
    }

    /// PlaybackSource.library with a single-track queue carries the right item.
    func testLibrarySingleTrackQueueCurrentItem() {
        let trk = makeTrack(id: "t-solo", title: "Karma Police")
        let source = PlaybackSource.library(queue: [trk], index: 0)
        XCTAssertEqual(source.currentItem.displayTitle, "Karma Police")
        XCTAssertFalse(source.currentItem.isLiveStream)
    }

    /// Confirm naviarome streamURL helper builds the expected path and id param —
    /// a lightweight integration check that doesn't require a live server.
    func testNavidromeAPIStreamURLBuildPath() {
        let api = NavidromeAPI(
            host: URL(string: "https://navidrome.test")!,
            username: "u",
            password: "p"
        )
        let url = api.streamURL(trackID: "t-1")
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.path, "/rest/stream.view")
        let items = URLComponents(string: url?.absoluteString ?? "")?.queryItems ?? []
        let idVal = items.first(where: { $0.name == "id" })?.value
        XCTAssertEqual(idVal, "t-1")
    }

    // MARK: - AudioPlayerService seam: playbackSource mirrors currentChannel

    @MainActor
    func testPlaybackSourceInitiallyNil() {
        let service = AudioPlayerService.shared
        // Smoke: default state is nil for both (singleton, no playback started)
        XCTAssertNil(service.playbackSource)
        XCTAssertNil(service.nowPlaying)
    }
}
