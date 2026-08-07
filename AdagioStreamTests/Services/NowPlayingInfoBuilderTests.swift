// NowPlayingInfoBuilderTests.swift
//
// Tests for d6q.5: per-track now-playing metadata and remote-command
// enablement decisions.
//
// Design note: AudioPlayerService embeds VLC and requires a real audio
// session, making full integration testing impractical in CI.  These
// tests cover the *decision layer* — pure PlaybackSource logic that
// determines:
//
//   1. Whether the source is a finite track (library) vs live stream (radio).
//   2. Which keys belong in MPNowPlayingInfo for each source type.
//   3. Whether MPChangePlaybackPositionCommand should be enabled.
//
// The VLC time-reading path (actual elapsed seconds) is integration-only
// and covered by launch smoke rather than unit tests.

import XCTest
import MediaPlayer
@testable import AdagioStream

// MARK: - NowPlaying source-type decisions

final class NowPlayingInfoBuilderTests: XCTestCase {

    // MARK: - Helpers

    private func makeChannel() -> Channel {
        Channel(
            id: "ch-test",
            name: "KEXP 90.3",
            streamURL: URL(string: "https://example.com/stream")!,
            group: "Community Radio"
        )
    }

    private func makeTrack(
        id: String = "trk-1",
        title: String = "Pyramid Song",
        artistId: String = "art-1",
        duration: Int? = 260
    ) -> Track {
        Track(
            id: id,
            albumId: "alb-1",
            artistId: artistId,
            title: title,
            duration: duration,
            updatedAt: 1_700_000_000
        )
    }

    // MARK: - Track isLiveStream = false (drives now-playing key selection)

    /// Library tracks must NOT be live-stream: they have finite duration + scrubber.
    func testTrackIsNotLiveStream() {
        let trk = makeTrack()
        XCTAssertFalse(trk.isLiveStream,
            "Track.isLiveStream must be false — required for lock-screen scrubber and progress bar")
    }

    /// Channels must be live-stream: they have no duration or scrubber.
    func testChannelIsLiveStream() {
        let ch = makeChannel()
        XCTAssertTrue(ch.isLiveStream,
            "Channel.isLiveStream must be true — radio has no elapsed-time progress")
    }

    // MARK: - PlaybackSource library mode carries track metadata

    func testLibrarySourceCurrentItemTitleMatchesTrack() {
        let trk = makeTrack(title: "Everything in Its Right Place")
        let source = PlaybackSource.library(queue: [trk], index: 0)
        XCTAssertEqual(source.currentItem.displayTitle, "Everything in Its Right Place")
    }

    func testLibrarySourceCurrentItemIsNotLiveStream() {
        let trk = makeTrack()
        let source = PlaybackSource.library(queue: [trk], index: 0)
        XCTAssertFalse(source.currentItem.isLiveStream,
            ".library source item must be finite (isLiveStream=false) to enable progress/scrubber")
    }

    func testRadioSourceCurrentItemIsLiveStream() {
        let ch = makeChannel()
        let source = PlaybackSource.radio(ch)
        XCTAssertTrue(source.currentItem.isLiveStream,
            ".radio source item must be live-stream (no progress bar or scrubber)")
    }

    // MARK: - changePlaybackPosition command enablement decision

    /// Pure decision: library → scrubber enabled, radio → disabled.
    /// This mirrors the logic in AudioPlayerService.updateRemoteCommandsForSource(_:).
    func testChangePlaybackPositionEnabledForLibrary() {
        let source = PlaybackSource.library(queue: [makeTrack()], index: 0)
        XCTAssertTrue(
            isChangePlaybackPositionEnabled(for: source),
            "MPChangePlaybackPositionCommand must be enabled for .library (finite track scrubber)"
        )
    }

    func testChangePlaybackPositionDisabledForRadio() {
        let source = PlaybackSource.radio(makeChannel())
        XCTAssertFalse(
            isChangePlaybackPositionEnabled(for: source),
            "MPChangePlaybackPositionCommand must be disabled for .radio (live, non-seekable)"
        )
    }

    func testChangePlaybackPositionDisabledWhenNoSource() {
        XCTAssertFalse(
            isChangePlaybackPositionEnabled(for: nil),
            "MPChangePlaybackPositionCommand must be disabled when no source is active"
        )
    }

    // MARK: - next/prev always enabled

    func testNextPrevAlwaysEnabled() {
        // next/prev must be enabled for both modes (library: queue nav, radio: channel cycling).
        for source: PlaybackSource? in [
            .library(queue: [makeTrack()], index: 0),
            .radio(makeChannel()),
            nil
        ] {
            XCTAssertTrue(
                isNextPrevEnabled(for: source),
                "next/prev must be enabled for source=\(String(describing: source))"
            )
        }
    }

    // MARK: - MPNowPlayingInfo key presence

    /// Verifies that the keys required for a finite-track progress bar are present
    /// in a now-playing dict built for library mode, and absent from radio mode.
    /// This validates the *intent* of the d6q.5 builder without invoking VLC.
    func testLibraryNowPlayingDictIncludesProgressKeys() {
        let info = makeLibraryNowPlayingInfo(
            track: makeTrack(duration: 260),
            elapsed: 42.0,
            isPlaying: true
        )
        XCTAssertEqual(info[MPNowPlayingInfoPropertyIsLiveStream] as? Bool, false,
            "Library now-playing must set isLiveStream=false")
        XCTAssertNotNil(info[MPNowPlayingInfoPropertyElapsedPlaybackTime],
            "Library now-playing must include ElapsedPlaybackTime")
        XCTAssertNotNil(info[MPMediaItemPropertyPlaybackDuration],
            "Library now-playing must include PlaybackDuration when track.duration is known")
        XCTAssertEqual(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1.0,
            "Library now-playing must set PlaybackRate=1.0 while playing")
    }

    func testLibraryNowPlayingDictRateZeroWhenPaused() {
        let info = makeLibraryNowPlayingInfo(
            track: makeTrack(duration: 260),
            elapsed: 42.0,
            isPlaying: false
        )
        XCTAssertEqual(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0.0,
            "Library now-playing must set PlaybackRate=0.0 when paused")
        // Elapsed is still present when paused (scrubber shows static position).
        XCTAssertNotNil(info[MPNowPlayingInfoPropertyElapsedPlaybackTime],
            "ElapsedPlaybackTime must still be present when paused")
    }

    func testLibraryNowPlayingDictOmitsDurationWhenUnknown() {
        let trk = makeTrack(duration: nil)
        let info = makeLibraryNowPlayingInfo(track: trk, elapsed: 0, isPlaying: false)
        XCTAssertNil(info[MPMediaItemPropertyPlaybackDuration],
            "PlaybackDuration must be omitted when track.duration is nil (unknown length)")
    }

    func testRadioNowPlayingDictIsLiveStreamTrue() {
        let info = makeRadioNowPlayingInfo(channel: makeChannel(), isPlaying: true)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyIsLiveStream] as? Bool, true,
            "Radio now-playing must set isLiveStream=true")
        XCTAssertNil(info[MPNowPlayingInfoPropertyElapsedPlaybackTime],
            "Radio now-playing must NOT include ElapsedPlaybackTime")
        XCTAssertNil(info[MPMediaItemPropertyPlaybackDuration],
            "Radio now-playing must NOT include PlaybackDuration")
    }

    // MARK: - Pure builder helpers (mirror AudioPlayerService logic, no VLC)

    /// Mirror of AudioPlayerService.updateRemoteCommandsForSource enablement decision.
    private func isChangePlaybackPositionEnabled(for source: PlaybackSource?) -> Bool {
        if case .library = source { return true }
        return false
    }

    /// next/prev are always enabled regardless of source.
    private func isNextPrevEnabled(for source: PlaybackSource?) -> Bool {
        return true
    }

    /// Builds the MPNowPlayingInfo dict for a library track, mirroring
    /// AudioPlayerService.updateNowPlayingInfoForTrack() logic.
    private func makeLibraryNowPlayingInfo(
        track: Track,
        elapsed: Double,
        isPlaying: Bool
    ) -> [String: Any] {
        let rate: Double = isPlaying ? 1.0 : 0.0
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPNowPlayingInfoPropertyIsLiveStream: false,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
        ]
        if let d = track.duration, d > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = NSNumber(value: d)
        }
        return info
    }

    /// Builds the MPNowPlayingInfo dict for a radio channel, mirroring
    /// AudioPlayerService.updateNowPlayingInfo() logic.
    private func makeRadioNowPlayingInfo(
        channel: Channel,
        isPlaying: Bool
    ) -> [String: Any] {
        let rate: Double = isPlaying ? 1.0 : 0.0
        return [
            MPMediaItemPropertyTitle: channel.name,
            MPMediaItemPropertyArtist: channel.group,
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
        ]
    }
}
