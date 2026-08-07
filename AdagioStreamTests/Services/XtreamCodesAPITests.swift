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

    // MARK: - Network retry (beads_mobilemusic-t96.5)
    //
    // Uses the same `MockURLProtocolHandler` harness as `NavidromeAPITests`.

    private func makeNetworkAPI(session: URLSession) -> XtreamCodesAPI {
        XtreamCodesAPI(
            host: URL(string: "http://example.com")!,
            username: "user1",
            password: "pass1",
            session: session,
            retryDelay: .zero
        )
    }

    override func setUp() {
        super.setUp()
        MockURLProtocolHandler.reset()
    }

    override func tearDown() {
        MockURLProtocolHandler.reset()
        super.tearDown()
    }

    func testHTTP500RetriesOnceThenThrowsServerError() async {
        let session = MockURLProtocolHandler.makeSession()
        let api = makeNetworkAPI(session: session)
        MockURLProtocolHandler.responseQueue = [
            .init(json: "{}", statusCode: 500),
            .init(json: "{}", statusCode: 500),
        ]

        do {
            _ = try await api.authenticate()
            XCTFail("Expected .serverError but authenticate() returned normally")
        } catch XtreamCodesAPI.APIError.serverError(let code) {
            XCTAssertEqual(code, 500)
            XCTAssertEqual(MockURLProtocolHandler.capturedRequests.count, 2,
                           "Expected exactly 2 requests (original + 1 retry)")
        } catch {
            XCTFail("Expected .serverError(500) but got: \(error)")
        }
    }

    func testHTTP500ThenSucceeds() async throws {
        let session = MockURLProtocolHandler.makeSession()
        let api = makeNetworkAPI(session: session)
        let authOK = """
            {"user_info":{"username":"user1","status":"Active","auth":1,"allowed_output_formats":["ts"]}}
            """
        MockURLProtocolHandler.responseQueue = [
            .init(json: "{}", statusCode: 500),
            .init(json: authOK, statusCode: 200),
        ]

        let response = try await api.authenticate()

        XCTAssertEqual(response.userInfo?.status, "Active")
        XCTAssertEqual(MockURLProtocolHandler.capturedRequests.count, 2,
                       "Expected original request + 1 retry")
    }

    func testAuthenticationFailedWhenNotActive() async {
        let session = MockURLProtocolHandler.makeSession()
        let api = makeNetworkAPI(session: session)
        let authFailed = """
            {"user_info":{"username":"user1","status":"Disabled","auth":0}}
            """
        MockURLProtocolHandler.responseQueue = [
            .init(json: authFailed, statusCode: 200),
        ]

        do {
            _ = try await api.authenticate()
            XCTFail("Expected .authenticationFailed but authenticate() returned normally")
        } catch XtreamCodesAPI.APIError.authenticationFailed {
            // Expected
        } catch {
            XCTFail("Expected .authenticationFailed but got: \(error)")
        }
    }
}
