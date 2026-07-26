// ChannelRowViewAccessibilityTests.swift
//
// uxd.1: ChannelRowView.accessibilityLabel(...) is the pure decision layer
// behind the row's combined VoiceOver label (which of track/game/EPG/group
// wins, plus the favorited suffix). Extracted as a static func so it's
// testable without spinning up SwiftUI.

import XCTest
@testable import AdagioStream

final class ChannelRowViewAccessibilityTests: XCTestCase {

    private func makeTrack(artist: String = "Radiohead", title: String = "Pyramid Song") -> SXMTrack {
        SXMTrack(id: "trk-1", title: title, artists: [artist], artworkURL: nil, startedAt: nil)
    }

    private func makeGame(state: ESPNGameInfo.GameState = .live) -> ESPNGameInfo {
        ESPNGameInfo(
            league: .mlb, awayAbbr: "MIN", homeAbbr: "BOS",
            awayScore: "3", homeScore: "0",
            awayRecord: nil, homeRecord: nil,
            state: state, statusDetail: "Bot 7th",
            displayClock: nil, period: 7, gameDate: nil,
            outs: nil, balls: nil, strikes: nil,
            onFirst: nil, onSecond: nil, onThird: nil,
            possessionTeamAbbr: nil, downDistanceText: nil
        )
    }

    private func makeProgram(title: String = "Morning Show") -> EPGEntry {
        EPGEntry(channelID: "ch-1", title: title, start: Date(), end: Date().addingTimeInterval(3600))
    }

    func testFallsBackToGroupWhenNothingElsePlaying() {
        let label = ChannelRowView.accessibilityLabel(
            channelName: "KEXP 90.3", group: "Community Radio", isFavorite: false,
            nowPlayingTrack: nil, espnGame: nil, currentProgram: nil
        )
        XCTAssertEqual(label, "KEXP 90.3, Community Radio")
    }

    func testPrefersNowPlayingTrackOverEverythingElse() {
        let label = ChannelRowView.accessibilityLabel(
            channelName: "KEXP 90.3", group: "Community Radio", isFavorite: false,
            nowPlayingTrack: makeTrack(), espnGame: makeGame(), currentProgram: makeProgram()
        )
        XCTAssertEqual(label, "KEXP 90.3, Radiohead — Pyramid Song")
    }

    func testPrefersESPNGameOverEPGProgramWhenNoTrack() {
        let label = ChannelRowView.accessibilityLabel(
            channelName: "ESPN Radio", group: "Sports", isFavorite: false,
            nowPlayingTrack: nil, espnGame: makeGame(), currentProgram: makeProgram()
        )
        XCTAssertTrue(label.hasPrefix("ESPN Radio, "))
        XCTAssertFalse(label.contains("Morning Show"))
    }

    func testFallsBackToEPGProgramWhenNoTrackOrGame() {
        let label = ChannelRowView.accessibilityLabel(
            channelName: "BBC Radio 1", group: "Talk", isFavorite: false,
            nowPlayingTrack: nil, espnGame: nil, currentProgram: makeProgram()
        )
        XCTAssertEqual(label, "BBC Radio 1, Morning Show")
    }

    func testAppendsFavoritedSuffixWhenFavorited() {
        let label = ChannelRowView.accessibilityLabel(
            channelName: "KEXP 90.3", group: "Community Radio", isFavorite: true,
            nowPlayingTrack: nil, espnGame: nil, currentProgram: nil
        )
        XCTAssertEqual(label, "KEXP 90.3, Community Radio, Favorited")
    }
}
