import XCTest
@testable import AdagioStream

final class M3UParserTests: XCTestCase {

    func testParseValidM3UWithAllAttributes() {
        let content = """
        #EXTM3U
        #EXTINF:-1 tvg-id="ch1" tvg-name="Channel One" tvg-logo="https://example.com/logo.png" group-title="News",Channel 1
        http://stream.example.com/live/1
        """

        let channels = M3UParser.parse(content: content)

        XCTAssertEqual(channels.count, 1)
        let ch = channels[0]
        XCTAssertEqual(ch.id, "ch1")
        XCTAssertEqual(ch.name, "Channel 1")
        XCTAssertEqual(ch.streamURL.absoluteString, "http://stream.example.com/live/1")
        XCTAssertEqual(ch.logoURL?.absoluteString, "https://example.com/logo.png")
        XCTAssertEqual(ch.group, "News")
        XCTAssertEqual(ch.epgChannelID, "ch1")
    }

    func testParseMissingOptionalAttributes() {
        let content = """
        #EXTM3U
        #EXTINF:-1,My Channel
        http://stream.example.com/live/2
        """

        let channels = M3UParser.parse(content: content)

        XCTAssertEqual(channels.count, 1)
        let ch = channels[0]
        XCTAssertEqual(ch.name, "My Channel")
        XCTAssertEqual(ch.group, "Uncategorized")
        XCTAssertNil(ch.logoURL)
        XCTAssertNil(ch.epgChannelID)
        // Auto-generated UUID id
        XCTAssertFalse(ch.id.isEmpty)
    }

    func testSkipInvalidURLSchemes() {
        let content = """
        #EXTM3U
        #EXTINF:-1 tvg-id="ch1",Good Channel
        http://stream.example.com/live/1
        #EXTINF:-1 tvg-id="ch2",Bad Channel
        ftp://files.example.com/stream
        """

        let channels = M3UParser.parse(content: content)

        XCTAssertEqual(channels.count, 1)
        XCTAssertEqual(channels[0].id, "ch1")
    }

    func testEmptyContentReturnsNoChannels() {
        XCTAssertTrue(M3UParser.parse(content: "").isEmpty)
        XCTAssertTrue(M3UParser.parse(content: "#EXTM3U\n").isEmpty)
    }

    func testEXTINFWithNoCommaFallsBackToTvgName() {
        let content = """
        #EXTM3U
        #EXTINF:-1 tvg-name="Fallback Name"
        http://stream.example.com/live/1
        """

        let channels = M3UParser.parse(content: content)

        XCTAssertEqual(channels.count, 1)
        XCTAssertEqual(channels[0].name, "Fallback Name")
    }

    func testMultipleChannels() {
        let content = """
        #EXTM3U
        #EXTINF:-1 tvg-id="ch1" group-title="Music",Music FM
        http://stream.example.com/1
        #EXTINF:-1 tvg-id="ch2" group-title="News",News 24
        https://stream.example.com/2
        #EXTINF:-1 tvg-id="ch3" group-title="Music",Jazz Radio
        rtsp://stream.example.com/3
        """

        let channels = M3UParser.parse(content: content)

        XCTAssertEqual(channels.count, 3)
        XCTAssertEqual(channels[0].name, "Music FM")
        XCTAssertEqual(channels[1].name, "News 24")
        XCTAssertEqual(channels[2].name, "Jazz Radio")
    }

    func testEmptyTvgIdGeneratesUniqueIDs() {
        let content = """
        #EXTM3U
        #EXTINF:-1 tvg-id="" tvg-name="" tvg-logo="https://example.com/a.png",Channel A
        http://stream.example.com/1
        #EXTINF:-1 tvg-id="" tvg-name="" tvg-logo="https://example.com/b.png",Channel B
        http://stream.example.com/2
        """

        let channels = M3UParser.parse(content: content)

        XCTAssertEqual(channels.count, 2)
        XCTAssertEqual(channels[0].name, "Channel A")
        XCTAssertEqual(channels[1].name, "Channel B")
        XCTAssertNotEqual(channels[0].id, channels[1].id, "Channels with empty tvg-id should get unique IDs")
        XCTAssertNil(channels[0].epgChannelID)
        XCTAssertNil(channels[1].epgChannelID)
    }

    func testEXTGRPUsedForGroup() {
        let content = """
        #EXTM3U
        #EXTINF:-1 tvg-id="ch1",Station One
        #EXTGRP:Radio
        http://stream.example.com/1
        #EXTINF:-1 tvg-id="ch2" group-title="Music",Station Two
        #EXTGRP:Radio
        http://stream.example.com/2
        """

        let channels = M3UParser.parse(content: content)

        XCTAssertEqual(channels.count, 2)
        XCTAssertEqual(channels[0].group, "Radio", "EXTGRP should be used when group-title is missing")
        XCTAssertEqual(channels[1].group, "Music", "group-title attribute should take precedence over EXTGRP")
    }

    func testRTMPAndMMSSchemesAccepted() {
        let content = """
        #EXTM3U
        #EXTINF:-1,RTMP Stream
        rtmp://stream.example.com/live/1
        #EXTINF:-1,MMS Stream
        mms://stream.example.com/live/2
        """

        let channels = M3UParser.parse(content: content)

        XCTAssertEqual(channels.count, 2)
    }
}
