import XCTest
@testable import AdagioStream

// ymf.1 — buildURL must preserve a reverse-proxy subpath in the host and must
// still work for a root-hosted server. Covers API paths and the token-bearing
// stream/cover URL builders.

final class AudiobookshelfAPITests: XCTestCase {

    override func setUp() {
        super.setUp()
        MockURLProtocolHandler.reset()
    }

    override func tearDown() {
        MockURLProtocolHandler.reset()
        super.tearDown()
    }

    private func makeAPI(host: String) -> AudiobookshelfAPI {
        let auth = AudiobookshelfAuth(
            host: URL(string: host)!,
            username: "u", password: "p", providerID: "PID",
            session: MockURLProtocolHandler.makeSession(),
            loadTokens: { _ in .init(accessToken: "TOK", refreshToken: "R") },
            saveTokens: { _, _ in }, clearTokens: { _ in }
        )
        return AudiobookshelfAPI(host: URL(string: host)!, auth: auth)
    }

    // MARK: - API path builder

    func testBuildURLPreservesSubpath() {
        let api = makeAPI(host: "https://h/audiobookshelf")
        let url = api.buildURL("/api/libraries", query: [:])
        XCTAssertEqual(url?.absoluteString, "https://h/audiobookshelf/api/libraries")
    }

    func testBuildURLRootHost() {
        let api = makeAPI(host: "https://h")
        let url = api.buildURL("/api/libraries", query: [:])
        XCTAssertEqual(url?.absoluteString, "https://h/api/libraries")
    }

    func testBuildURLRootHostWithTrailingSlash() {
        let api = makeAPI(host: "https://h/")
        let url = api.buildURL("/api/libraries", query: [:])
        XCTAssertEqual(url?.absoluteString, "https://h/api/libraries")
    }

    func testBuildURLSubpathTrailingSlashNoDoubleSlash() {
        let api = makeAPI(host: "https://h/audiobookshelf/")
        let url = api.buildURL("/api/libraries", query: [:])
        XCTAssertEqual(url?.absoluteString, "https://h/audiobookshelf/api/libraries")
    }

    // MARK: - token-in-query survives on subpath + root

    func testBuildURLCarriesTokenQueryOnSubpath() {
        let api = makeAPI(host: "https://h/audiobookshelf")
        let url = api.buildURL("/api/items/X/cover", query: ["token": "JWT", "width": "400"])
        let comps = URLComponents(url: url!, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(comps.path, "/audiobookshelf/api/items/X/cover")
        XCTAssertEqual(comps.queryItems?.first(where: { $0.name == "token" })?.value, "JWT")
    }

    // MARK: - stream URL (server-relative contentPath) preserves subpath + token

    func testStreamURLPreservesSubpathAndToken() async {
        let api = makeAPI(host: "https://h/audiobookshelf")
        let url = await api.streamURL(contentPath: "/s/item/abc/track.m4b")
        let comps = URLComponents(url: url!, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(comps.path, "/audiobookshelf/s/item/abc/track.m4b")
        XCTAssertEqual(comps.queryItems?.first(where: { $0.name == "token" })?.value, "TOK")
    }

    func testStreamURLRootHost() async {
        let api = makeAPI(host: "https://h")
        let url = await api.streamURL(contentPath: "/s/item/abc/track.m4b")
        XCTAssertEqual(url?.absoluteString, "https://h/s/item/abc/track.m4b?token=TOK")
    }

    func testCoverURLPreservesSubpath() async {
        let api = makeAPI(host: "https://h/audiobookshelf")
        let url = await api.coverURL(itemID: "abc")
        let comps = URLComponents(url: url!, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(comps.path, "/audiobookshelf/api/items/abc/cover")
        XCTAssertEqual(comps.queryItems?.first(where: { $0.name == "token" })?.value, "TOK")
    }

    // MARK: - 5aj.1: batched progress fetch (GET /api/me)

    func testAllMediaProgressDecodesBatchedRecords() async {
        let api = makeAPI(host: "https://h")
        let json = """
        { "mediaProgress": [
            { "libraryItemId": "show-a", "episodeId": "ep-1", "currentTime": 10.0, "progress": 0.1, "isFinished": false },
            { "libraryItemId": "show-a", "episodeId": "ep-2", "currentTime": 20.0, "progress": 0.2, "isFinished": true }
        ] }
        """
        MockURLProtocolHandler.responseQueue = [.init(json: json)]
        let records = await api.allMediaProgress()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.first?.libraryItemId, "show-a")
        XCTAssertEqual(records.first?.episodeId, "ep-1")
        XCTAssertEqual(MockURLProtocolHandler.capturedRequests.first?.url?.path, "/api/me")
    }

    func testAllMediaProgressReturnsEmptyOnServerError() async {
        let api = makeAPI(host: "https://h")
        MockURLProtocolHandler.responseQueue = [.init(json: "{}", statusCode: 500)]
        let records = await api.allMediaProgress()
        XCTAssertTrue(records.isEmpty)
    }
}
