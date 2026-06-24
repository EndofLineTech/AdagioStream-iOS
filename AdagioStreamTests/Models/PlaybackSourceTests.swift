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

    private func makeTrack(id: String = "trk-1", title: String = "Pyramid Song", artistId: String = "art-radiohead") -> Track {
        Track(
            id: id,
            albumId: "alb-1",
            artistId: artistId,
            title: title,
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

    func testTrackDisplaySubtitle() {
        let trk = makeTrack(artistId: "art-radiohead")
        // Phase 1: subtitle is the artistId until d6q.2 wires the artist name
        XCTAssertEqual(trk.displaySubtitle, "art-radiohead")
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

    // MARK: - AudioPlayerService seam: playbackSource mirrors currentChannel

    @MainActor
    func testPlaybackSourceInitiallyNil() {
        let service = AudioPlayerService.shared
        // Smoke: default state is nil for both (singleton, no playback started)
        XCTAssertNil(service.playbackSource)
        XCTAssertNil(service.nowPlaying)
    }
}
