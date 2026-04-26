import AdagioStreamCore
import XCTest
@testable import AdagioStream

final class XtreamCodesAPITests: XCTestCase {

    private func makeAPI(host: String = "http://example.com") -> XtreamCodesAPI {
        XtreamCodesAPI(host: URL(string: host)!, username: "user1", password: "pass1")
    }

    // MARK: - convertToChannels

    func testConvertToChannelsMapsStreamsAndCategories() {
        let api = makeAPI()
        let categories = [
            XtreamCodesAPI.Category(categoryID: "10", categoryName: "Music"),
            XtreamCodesAPI.Category(categoryID: "20", categoryName: "News"),
        ]
        let streams = [
            XtreamCodesAPI.LiveStream(streamID: 1, name: "Jazz FM", streamIcon: "https://img.example.com/jazz.png", epgChannelID: "jazz.fm", categoryID: "10"),
            XtreamCodesAPI.LiveStream(streamID: 2, name: "CNN", streamIcon: nil, epgChannelID: "cnn.us", categoryID: "20"),
        ]

        let channels = api.convertToChannels(streams: streams, categories: categories)

        XCTAssertEqual(channels.count, 2)

        XCTAssertEqual(channels[0].id, "1")
        XCTAssertEqual(channels[0].name, "Jazz FM")
        XCTAssertEqual(channels[0].logoURL?.absoluteString, "https://img.example.com/jazz.png")
        XCTAssertEqual(channels[0].group, "Music")
        XCTAssertEqual(channels[0].epgChannelID, "jazz.fm")

        XCTAssertEqual(channels[1].id, "2")
        XCTAssertEqual(channels[1].name, "CNN")
        XCTAssertNil(channels[1].logoURL)
        XCTAssertEqual(channels[1].group, "News")
    }

    // MARK: - streamURL

    func testStreamURLBuildsCorrectPath() {
        let api = makeAPI()

        let url = api.streamURL(for: 42)

        XCTAssertEqual(url?.absoluteString, "http://example.com/live/user1/pass1/42.ts")
    }

    func testStreamURLWithCustomExtension() {
        let api = makeAPI()

        let url = api.streamURL(for: 42, extension: "m3u8")

        XCTAssertEqual(url?.absoluteString, "http://example.com/live/user1/pass1/42.m3u8")
    }

    // MARK: - Category lookup

    func testMissingCategoryDefaultsToUncategorized() {
        let api = makeAPI()
        let categories = [
            XtreamCodesAPI.Category(categoryID: "10", categoryName: "Music"),
        ]
        let streams = [
            XtreamCodesAPI.LiveStream(streamID: 1, name: "Orphan Stream", streamIcon: nil, epgChannelID: nil, categoryID: "999"),
        ]

        let channels = api.convertToChannels(streams: streams, categories: categories)

        XCTAssertEqual(channels.count, 1)
        XCTAssertEqual(channels[0].group, "Uncategorized")
    }

    func testNilCategoryIDDefaultsToUncategorized() {
        let api = makeAPI()
        let streams = [
            XtreamCodesAPI.LiveStream(streamID: 1, name: "No Category", streamIcon: nil, epgChannelID: nil, categoryID: nil),
        ]

        let channels = api.convertToChannels(streams: streams, categories: [])

        XCTAssertEqual(channels[0].group, "Uncategorized")
    }

    // MARK: - Missing stream name

    func testMissingStreamNameDefaultsToUnknown() {
        let api = makeAPI()
        let streams = [
            XtreamCodesAPI.LiveStream(streamID: 1, name: nil, streamIcon: nil, epgChannelID: nil, categoryID: nil),
        ]

        let channels = api.convertToChannels(streams: streams, categories: [])

        XCTAssertEqual(channels[0].name, "Unknown")
    }
}
