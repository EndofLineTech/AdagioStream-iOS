import XCTest
@testable import AdagioStream

// MARK: - URLProtocol stub for injected sessions

/// A URLProtocol subclass that intercepts requests and returns pre-configured
/// fixture data without hitting the network.  One instance is registered per
/// test via `MockURLProtocolHandler.register` and cleared in tearDown.
final class MockURLProtocolHandler: URLProtocol {

    // MARK: - Per-test configuration

    struct Response {
        let data: Data
        let statusCode: Int
        let headers: [String: String]

        init(data: Data, statusCode: Int = 200, headers: [String: String] = [:]) {
            self.data = data
            self.statusCode = statusCode
            self.headers = headers
        }

        init(json: String, statusCode: Int = 200) {
            self.init(data: Data(json.utf8), statusCode: statusCode)
        }
    }

    /// Requests captured during the test — indexed by invocation order.
    static var capturedRequests: [URLRequest] = []
    /// Responses to return — each call pops the first entry; last entry repeats.
    static var responseQueue: [Response] = []
    /// When non-nil, throw this error instead of returning a response.
    static var stubbedError: Error?

    static func reset() {
        capturedRequests = []
        responseQueue = []
        stubbedError = nil
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocolHandler.self]
        config.timeoutIntervalForRequest = 5
        return URLSession(configuration: config)
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        MockURLProtocolHandler.capturedRequests.append(request)

        if let error = MockURLProtocolHandler.stubbedError {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        let response: MockURLProtocolHandler.Response
        if MockURLProtocolHandler.responseQueue.count > 1 {
            response = MockURLProtocolHandler.responseQueue.removeFirst()
        } else {
            response = MockURLProtocolHandler.responseQueue.first ?? Response(json: "{}")
        }

        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: response.headers
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Test fixtures (inline JSON — avoids resource-path bundling complexity)

private enum Fixtures {
    static let pingOK = """
        {"subsonic-response":{"status":"ok","version":"1.16.1"}}
        """

    static let pingAuthFailed = """
        {"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":40,"message":"Wrong username or password"}}}
        """

    static let pingFailed50 = """
        {"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":50,"message":"Permission denied"}}}
        """

    static let smallPayload = """
        {"subsonic-response":{"status":"ok","version":"1.16.1","greeting":"hello"}}
        """

    static let htmlGarbage = """
        <html><body>Not a Subsonic server</body></html>
        """
}

// MARK: - Helper Decodable for generic fetch test

/// A minimal Decodable whose keys live inside the `"subsonic-response"` object.
private struct GreetingPayload: Decodable {
    let status: String
    let version: String
    let greeting: String?
}

// MARK: - Test cases

final class NavidromeAPITests: XCTestCase {

    private var session: URLSession!
    private var api: NavidromeAPI!

    override func setUp() {
        super.setUp()
        MockURLProtocolHandler.reset()
        session = MockURLProtocolHandler.makeSession()
        api = NavidromeAPI(
            host: URL(string: "http://navidrome.example.com")!,
            username: "alice",
            password: "sesame",
            session: session
        )
    }

    override func tearDown() {
        MockURLProtocolHandler.reset()
        super.tearDown()
    }

    // MARK: - ping success

    func testPingSuccessDoesNotThrow() async throws {
        MockURLProtocolHandler.responseQueue = [
            .init(json: Fixtures.pingOK)
        ]

        // Should return without throwing.
        try await api.ping()
    }

    // MARK: - ping auth failure (error code 40)

    func testPingAuthFailureThrowsAuthenticationFailed() async {
        MockURLProtocolHandler.responseQueue = [
            .init(json: Fixtures.pingAuthFailed)
        ]

        do {
            try await api.ping()
            XCTFail("Expected authenticationFailed but ping() returned normally")
        } catch NavidromeAPI.APIError.authenticationFailed {
            // Expected — code 40 maps to .authenticationFailed
        } catch {
            XCTFail("Expected .authenticationFailed but got: \(error)")
        }
    }

    /// Confirm the subsonicError case also surfaces code and message for non-auth failures.
    func testPingFailedCode50ThrowsSubsonicError() async {
        MockURLProtocolHandler.responseQueue = [
            .init(json: Fixtures.pingFailed50)
        ]

        do {
            try await api.ping()
            XCTFail("Expected .subsonicError but ping() returned normally")
        } catch NavidromeAPI.APIError.subsonicError(let code, let message) {
            XCTAssertEqual(code, 50)
            XCTAssertEqual(message, "Permission denied")
        } catch {
            XCTFail("Expected .subsonicError but got: \(error)")
        }
    }

    // MARK: - Generic fetch decodes payload through envelope

    func testFetchDecodesPayloadThroughEnvelope() async throws {
        MockURLProtocolHandler.responseQueue = [
            .init(json: Fixtures.smallPayload)
        ]

        let payload = try await api.fetch("greeting", params: [:], as: GreetingPayload.self)

        XCTAssertEqual(payload.status, "ok")
        XCTAssertEqual(payload.version, "1.16.1")
        XCTAssertEqual(payload.greeting, "hello")
    }

    // MARK: - HTTP 500 → retry once → .serverError(500)

    func testHTTP500RetriesOnceThenThrowsServerError() async {
        // Return 500 twice — first attempt + the one retry.
        MockURLProtocolHandler.responseQueue = [
            .init(json: "{}", statusCode: 500),
            .init(json: "{}", statusCode: 500),
        ]

        do {
            try await api.ping()
            XCTFail("Expected .serverError but ping() returned normally")
        } catch NavidromeAPI.APIError.serverError(let code) {
            XCTAssertEqual(code, 500)
            // Both responses should have been consumed (initial + 1 retry).
            XCTAssertEqual(MockURLProtocolHandler.capturedRequests.count, 2,
                           "Expected exactly 2 requests (original + 1 retry)")
        } catch {
            XCTFail("Expected .serverError(500) but got: \(error)")
        }
    }

    func testHTTP500FirstThen200ReturnsSuccess() async throws {
        // First attempt → 500; retry → 200 OK.
        MockURLProtocolHandler.responseQueue = [
            .init(json: "{}", statusCode: 500),
            .init(json: Fixtures.pingOK, statusCode: 200),
        ]

        try await api.ping()

        XCTAssertEqual(MockURLProtocolHandler.capturedRequests.count, 2,
                       "Expected original request + 1 retry")
    }

    // MARK: - Non-Subsonic body → .notSubsonicServer

    func testHTMLBodyThrowsNotSubsonicServer() async {
        MockURLProtocolHandler.responseQueue = [
            .init(json: Fixtures.htmlGarbage, statusCode: 200)
        ]

        do {
            try await api.ping()
            XCTFail("Expected .notSubsonicServer but ping() returned normally")
        } catch NavidromeAPI.APIError.notSubsonicServer {
            // Expected
        } catch {
            XCTFail("Expected .notSubsonicServer but got: \(error)")
        }
    }

    func testValidJSONButNoSubsonicKeyThrowsNotSubsonicServer() async {
        MockURLProtocolHandler.responseQueue = [
            .init(json: #"{"message":"not subsonic","code":200}"#, statusCode: 200)
        ]

        do {
            try await api.ping()
            XCTFail("Expected .notSubsonicServer but ping() returned normally")
        } catch NavidromeAPI.APIError.notSubsonicServer {
            // Expected
        } catch {
            XCTFail("Expected .notSubsonicServer but got: \(error)")
        }
    }

    // MARK: - URL contains auth query params

    func testRequestURLContainsAllAuthQueryParams() async throws {
        MockURLProtocolHandler.responseQueue = [
            .init(json: Fixtures.pingOK)
        ]

        try await api.ping()

        let captured = MockURLProtocolHandler.capturedRequests.first
        XCTAssertNotNil(captured, "Expected at least one captured request")

        let urlString = captured?.url?.absoluteString ?? ""
        let components = URLComponents(string: urlString)
        let items = components?.queryItems ?? []

        func queryValue(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value
        }

        XCTAssertEqual(queryValue("u"), "alice", "u= param must match username")
        XCTAssertNotNil(queryValue("t"), "t= (token) must be present")
        XCTAssertNotNil(queryValue("s"), "s= (salt) must be present")
        XCTAssertEqual(queryValue("c"), SubsonicAuth.clientName)
        XCTAssertEqual(queryValue("v"), SubsonicAuth.apiVersion)
        XCTAssertEqual(queryValue("f"), "json")
    }

    func testRequestURLContainsPingEndpointPath() async throws {
        MockURLProtocolHandler.responseQueue = [
            .init(json: Fixtures.pingOK)
        ]

        try await api.ping()

        let path = MockURLProtocolHandler.capturedRequests.first?.url?.path
        XCTAssertEqual(path, "/rest/ping.view")
    }

    // MARK: - Password not in description / debugDescription

    func testPasswordAbsentFromDescription() {
        XCTAssertFalse(api.description.contains("sesame"),
                       "Password must not appear in description")
    }

    func testPasswordAbsentFromDebugDescription() {
        XCTAssertFalse(api.debugDescription.contains("sesame"),
                       "Password must not appear in debugDescription")
    }

    // MARK: - getArtists: flattens index buckets

    func testGetArtistsFlattensIndexBuckets() async throws {
        let json = """
        {"subsonic-response":{"status":"ok","version":"1.16.1","artists":{"index":[
            {"name":"A","artist":[{"id":"a1","name":"Adele","albumCount":3}]},
            {"name":"B","artist":[{"id":"b1","name":"Beatles","albumCount":13},{"id":"b2","name":"Blur","albumCount":7}]}
        ]}}}
        """
        MockURLProtocolHandler.responseQueue = [.init(json: json)]

        let artists = try await api.getArtists()

        XCTAssertEqual(artists.count, 3)
        XCTAssertEqual(artists[0].id, "a1")
        XCTAssertEqual(artists[0].name, "Adele")
        XCTAssertEqual(artists[0].albumCount, 3)
        XCTAssertEqual(artists[1].id, "b1")
        XCTAssertEqual(artists[2].id, "b2")
        XCTAssertEqual(artists[2].name, "Blur")
    }

    func testGetArtistsEmptyIndexReturnsEmptyArray() async throws {
        let json = """
        {"subsonic-response":{"status":"ok","version":"1.16.1","artists":{"index":[]}}}
        """
        MockURLProtocolHandler.responseQueue = [.init(json: json)]

        let artists = try await api.getArtists()
        XCTAssertTrue(artists.isEmpty)
    }

    func testGetArtistsBucketWithMissingArtistArrayDecodesToEmpty() async throws {
        // A bucket with no "artist" key at all — must not throw.
        let json = """
        {"subsonic-response":{"status":"ok","version":"1.16.1","artists":{"index":[
            {"name":"#"}
        ]}}}
        """
        MockURLProtocolHandler.responseQueue = [.init(json: json)]

        let artists = try await api.getArtists()
        XCTAssertTrue(artists.isEmpty)
    }

    // MARK: - getArtist: returns artist + albums

    func testGetArtistReturnsArtistAndAlbums() async throws {
        let json = """
        {"subsonic-response":{"status":"ok","version":"1.16.1","artist":{
            "id":"ar1","name":"Radiohead","albumCount":9,"coverArt":"art-ar1",
            "album":[
                {"id":"al1","artistId":"ar1","name":"OK Computer","songCount":12,"year":1997},
                {"id":"al2","artistId":"ar1","name":"Kid A","songCount":10,"year":2000}
            ]
        }}}
        """
        MockURLProtocolHandler.responseQueue = [.init(json: json)]

        let (artist, albums) = try await api.getArtist(id: "ar1")

        XCTAssertEqual(artist.id, "ar1")
        XCTAssertEqual(artist.name, "Radiohead")
        XCTAssertEqual(artist.albumCount, 9)
        XCTAssertEqual(artist.coverArt, "art-ar1")
        XCTAssertEqual(albums.count, 2)
        XCTAssertEqual(albums[0].id, "al1")
        XCTAssertEqual(albums[0].title, "OK Computer")
        XCTAssertEqual(albums[0].trackCount, 12)
        XCTAssertEqual(albums[0].year, 1997)
        XCTAssertEqual(albums[1].id, "al2")
    }

    func testGetArtistWithNoAlbumsKeyDecodesToEmptyAlbums() async throws {
        // "album" key absent — must not throw; returns []
        let json = """
        {"subsonic-response":{"status":"ok","version":"1.16.1","artist":{
            "id":"ar2","name":"Solo Artist"
        }}}
        """
        MockURLProtocolHandler.responseQueue = [.init(json: json)]

        let (artist, albums) = try await api.getArtist(id: "ar2")
        XCTAssertEqual(artist.id, "ar2")
        XCTAssertTrue(albums.isEmpty)
    }

    // MARK: - getAlbum: returns album + tracks with correct track numbers

    func testGetAlbumReturnsSongsWithTrackNumbers() async throws {
        let json = """
        {"subsonic-response":{"status":"ok","version":"1.16.1","album":{
            "id":"al1","artistId":"ar1","title":"OK Computer","songCount":3,"year":1997,
            "song":[
                {"id":"t1","albumId":"al1","artistId":"ar1","title":"Airbag","track":1,"duration":228},
                {"id":"t2","albumId":"al1","artistId":"ar1","title":"Paranoid Android","track":2,"duration":387},
                {"id":"t3","albumId":"al1","artistId":"ar1","title":"Subterranean Homesick Alien","track":3,"duration":271}
            ]
        }}}
        """
        MockURLProtocolHandler.responseQueue = [.init(json: json)]

        let (album, tracks) = try await api.getAlbum(id: "al1")

        XCTAssertEqual(album.id, "al1")
        XCTAssertEqual(album.title, "OK Computer")
        XCTAssertEqual(album.artistId, "ar1")
        XCTAssertEqual(tracks.count, 3)
        XCTAssertEqual(tracks[0].id, "t1")
        XCTAssertEqual(tracks[0].trackNumber, 1)
        XCTAssertEqual(tracks[0].duration, 228)
        XCTAssertEqual(tracks[1].trackNumber, 2)
        XCTAssertEqual(tracks[1].title, "Paranoid Android")
        XCTAssertEqual(tracks[2].trackNumber, 3)
    }

    func testGetAlbumWithNoSongKeyDecodesToEmptyTracks() async throws {
        // "song" key absent — must not throw
        let json = """
        {"subsonic-response":{"status":"ok","version":"1.16.1","album":{
            "id":"al9","artistId":"ar9","title":"Empty Album"
        }}}
        """
        MockURLProtocolHandler.responseQueue = [.init(json: json)]

        let (album, tracks) = try await api.getAlbum(id: "al9")
        XCTAssertEqual(album.id, "al9")
        XCTAssertTrue(tracks.isEmpty)
    }

    // MARK: - getAlbumList2: maps to [Album]

    func testGetAlbumList2MapsAlbums() async throws {
        let json = """
        {"subsonic-response":{"status":"ok","version":"1.16.1","albumList2":{
            "album":[
                {"id":"al1","artistId":"ar1","name":"Album One","songCount":8,"year":2020},
                {"id":"al2","artistId":"ar2","name":"Album Two","songCount":12,"year":2021}
            ]
        }}}
        """
        MockURLProtocolHandler.responseQueue = [.init(json: json)]

        let albums = try await api.getAlbumList2(type: .newest, size: 2, offset: 0)

        XCTAssertEqual(albums.count, 2)
        XCTAssertEqual(albums[0].id, "al1")
        XCTAssertEqual(albums[0].title, "Album One")
        XCTAssertEqual(albums[0].trackCount, 8)
        XCTAssertEqual(albums[1].id, "al2")
        XCTAssertEqual(albums[1].title, "Album Two")
        XCTAssertEqual(albums[1].year, 2021)
    }

    func testGetAlbumList2MissingAlbumKeyDecodesToEmpty() async throws {
        // "album" key absent in albumList2 wrapper — must not throw
        let json = """
        {"subsonic-response":{"status":"ok","version":"1.16.1","albumList2":{}}}
        """
        MockURLProtocolHandler.responseQueue = [.init(json: json)]

        let albums = try await api.getAlbumList2(type: .random)
        XCTAssertTrue(albums.isEmpty)
    }

    func testGetAlbumList2RequestURLContainsTypeAndSize() async throws {
        let json = """
        {"subsonic-response":{"status":"ok","version":"1.16.1","albumList2":{"album":[]}}}
        """
        MockURLProtocolHandler.responseQueue = [.init(json: json)]

        _ = try await api.getAlbumList2(type: .alphabeticalByName, size: 25, offset: 50)

        let captured = MockURLProtocolHandler.capturedRequests.first
        let items = URLComponents(string: captured?.url?.absoluteString ?? "")?.queryItems ?? []
        func q(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }

        XCTAssertEqual(q("type"), "alphabeticalByName")
        XCTAssertEqual(q("size"), "25")
        XCTAssertEqual(q("offset"), "50")
    }

    // MARK: - getGenres: maps value → name

    func testGetGenresMapsValueToName() async throws {
        let json = """
        {"subsonic-response":{"status":"ok","version":"1.16.1","genres":{
            "genre":[
                {"value":"Rock","songCount":42,"albumCount":8},
                {"value":"Jazz","songCount":17,"albumCount":3}
            ]
        }}}
        """
        MockURLProtocolHandler.responseQueue = [.init(json: json)]

        let genres = try await api.getGenres()

        XCTAssertEqual(genres.count, 2)
        XCTAssertEqual(genres[0].name, "Rock")
        XCTAssertEqual(genres[0].songCount, 42)
        XCTAssertEqual(genres[0].albumCount, 8)
        XCTAssertEqual(genres[1].name, "Jazz")
        XCTAssertEqual(genres[1].songCount, 17)
    }

    func testGetGenresMissingGenreKeyDecodesToEmpty() async throws {
        // "genre" array absent — must not throw
        let json = """
        {"subsonic-response":{"status":"ok","version":"1.16.1","genres":{}}}
        """
        MockURLProtocolHandler.responseQueue = [.init(json: json)]

        let genres = try await api.getGenres()
        XCTAssertTrue(genres.isEmpty)
    }

    // MARK: - getSongsByGenre: maps to [Track]

    func testGetSongsByGenreMapsToTracks() async throws {
        let json = """
        {"subsonic-response":{"status":"ok","version":"1.16.1","songsByGenre":{
            "song":[
                {"id":"s1","albumId":"al1","artistId":"ar1","title":"Stairway to Heaven","track":4,"duration":482,"genre":"Rock"},
                {"id":"s2","albumId":"al2","artistId":"ar1","title":"Kashmir","track":2,"duration":515,"genre":"Rock"}
            ]
        }}}
        """
        MockURLProtocolHandler.responseQueue = [.init(json: json)]

        let tracks = try await api.getSongsByGenre(genre: "Rock", count: 2, offset: 0)

        XCTAssertEqual(tracks.count, 2)
        XCTAssertEqual(tracks[0].id, "s1")
        XCTAssertEqual(tracks[0].title, "Stairway to Heaven")
        XCTAssertEqual(tracks[0].trackNumber, 4)
        XCTAssertEqual(tracks[0].duration, 482)
        XCTAssertEqual(tracks[0].genre, "Rock")
        XCTAssertEqual(tracks[1].id, "s2")
        XCTAssertEqual(tracks[1].trackNumber, 2)
    }

    func testGetSongsByGenreMissingSongKeyDecodesToEmpty() async throws {
        // "song" array absent — must not throw
        let json = """
        {"subsonic-response":{"status":"ok","version":"1.16.1","songsByGenre":{}}}
        """
        MockURLProtocolHandler.responseQueue = [.init(json: json)]

        let tracks = try await api.getSongsByGenre(genre: "Classical", count: 10, offset: 0)
        XCTAssertTrue(tracks.isEmpty)
    }

    func testGetSongsByGenreRequestURLContainsGenreCountOffset() async throws {
        let json = """
        {"subsonic-response":{"status":"ok","version":"1.16.1","songsByGenre":{"song":[]}}}
        """
        MockURLProtocolHandler.responseQueue = [.init(json: json)]

        _ = try await api.getSongsByGenre(genre: "Jazz", count: 50, offset: 20)

        let captured = MockURLProtocolHandler.capturedRequests.first
        let items = URLComponents(string: captured?.url?.absoluteString ?? "")?.queryItems ?? []
        func q(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }

        XCTAssertEqual(q("genre"), "Jazz")
        XCTAssertEqual(q("count"), "50")
        XCTAssertEqual(q("offset"), "20")
    }

    func testGetArtistsUpdatedAtIsPopulated() async throws {
        let before = Int(Date().timeIntervalSince1970)
        let json = """
        {"subsonic-response":{"status":"ok","version":"1.16.1","artists":{"index":[
            {"name":"A","artist":[{"id":"a1","name":"Artist One","albumCount":1}]}
        ]}}}
        """
        MockURLProtocolHandler.responseQueue = [.init(json: json)]

        let artists = try await api.getArtists()
        let after = Int(Date().timeIntervalSince1970)

        XCTAssertFalse(artists.isEmpty)
        let updatedAt = artists[0].updatedAt
        XCTAssertGreaterThanOrEqual(updatedAt, before, "updatedAt must be >= time before call")
        XCTAssertLessThanOrEqual(updatedAt, after,   "updatedAt must be <= time after call")
    }

    // MARK: - streamURL (d6q.2)

    func testStreamURLBuildsCorrectPath() {
        let url = api.streamURL(trackID: "trk-99")
        XCTAssertNotNil(url, "streamURL must return a non-nil URL")
        XCTAssertEqual(url?.path, "/rest/stream.view")
    }

    func testStreamURLContainsTrackID() {
        let url = api.streamURL(trackID: "trk-abc")
        let items = URLComponents(string: url?.absoluteString ?? "")?.queryItems ?? []
        let idParam = items.first(where: { $0.name == "id" })?.value
        XCTAssertEqual(idParam, "trk-abc")
    }

    func testStreamURLContainsAllAuthQueryParams() {
        let url = api.streamURL(trackID: "trk-1")
        let items = URLComponents(string: url?.absoluteString ?? "")?.queryItems ?? []
        func q(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }

        XCTAssertEqual(q("u"), "alice")
        XCTAssertNotNil(q("t"), "token must be present")
        XCTAssertNotNil(q("s"), "salt must be present")
        XCTAssertEqual(q("c"), SubsonicAuth.clientName)
        XCTAssertEqual(q("v"), SubsonicAuth.apiVersion)
        XCTAssertEqual(q("f"), "json")
    }

    func testStreamURLIncludesMaxBitRateWhenProvided() {
        let url = api.streamURL(trackID: "trk-1", maxBitRate: 320)
        let items = URLComponents(string: url?.absoluteString ?? "")?.queryItems ?? []
        let maxBR = items.first(where: { $0.name == "maxBitRate" })?.value
        XCTAssertEqual(maxBR, "320")
    }

    func testStreamURLOmitsMaxBitRateWhenNil() {
        let url = api.streamURL(trackID: "trk-1", maxBitRate: nil)
        let items = URLComponents(string: url?.absoluteString ?? "")?.queryItems ?? []
        let maxBR = items.first(where: { $0.name == "maxBitRate" })?.value
        XCTAssertNil(maxBR, "maxBitRate must be absent when not specified")
    }

    func testStreamURLIncludesFormatWhenProvided() {
        let url = api.streamURL(trackID: "trk-1", format: "mp3")
        let items = URLComponents(string: url?.absoluteString ?? "")?.queryItems ?? []
        let fmt = items.first(where: { $0.name == "format" })?.value
        XCTAssertEqual(fmt, "mp3")
    }

    func testStreamURLOmitsFormatWhenNil() {
        let url = api.streamURL(trackID: "trk-1", format: nil)
        let items = URLComponents(string: url?.absoluteString ?? "")?.queryItems ?? []
        let fmt = items.first(where: { $0.name == "format" })?.value
        XCTAssertNil(fmt, "format must be absent when not specified")
    }

    func testStreamURLHostIsPreserved() {
        let url = api.streamURL(trackID: "trk-1")
        XCTAssertEqual(url?.host, "navidrome.example.com")
    }

    // MARK: - coverArtURL (d6q.2)

    func testCoverArtURLBuildsCorrectPath() {
        let url = api.coverArtURL(id: "art-42")
        XCTAssertNotNil(url, "coverArtURL must return a non-nil URL")
        XCTAssertEqual(url?.path, "/rest/getCoverArt.view")
    }

    func testCoverArtURLContainsCoverArtID() {
        let url = api.coverArtURL(id: "art-42")
        let items = URLComponents(string: url?.absoluteString ?? "")?.queryItems ?? []
        let idParam = items.first(where: { $0.name == "id" })?.value
        XCTAssertEqual(idParam, "art-42")
    }

    func testCoverArtURLContainsAuthParams() {
        let url = api.coverArtURL(id: "art-1")
        let items = URLComponents(string: url?.absoluteString ?? "")?.queryItems ?? []
        func q(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }

        XCTAssertEqual(q("u"), "alice")
        XCTAssertNotNil(q("t"))
        XCTAssertNotNil(q("s"))
        XCTAssertEqual(q("c"), SubsonicAuth.clientName)
    }

    func testCoverArtURLIncludesSizeWhenProvided() {
        let url = api.coverArtURL(id: "art-1", size: 300)
        let items = URLComponents(string: url?.absoluteString ?? "")?.queryItems ?? []
        let size = items.first(where: { $0.name == "size" })?.value
        XCTAssertEqual(size, "300")
    }

    func testCoverArtURLOmitsSizeWhenNil() {
        let url = api.coverArtURL(id: "art-1", size: nil)
        let items = URLComponents(string: url?.absoluteString ?? "")?.queryItems ?? []
        let size = items.first(where: { $0.name == "size" })?.value
        XCTAssertNil(size, "size must be absent when not specified")
    }

    // MARK: - search3

    /// Full result: artists + albums + songs all present.
    func testSearch3PopulatedResultDecodesAllThreeArrays() async throws {
        let json = """
        {"subsonic-response":{"status":"ok","version":"1.16.1","searchResult3":{
            "artist":[
                {"id":"ar1","name":"Radiohead","albumCount":9}
            ],
            "album":[
                {"id":"al1","artistId":"ar1","title":"OK Computer","songCount":12,"year":1997}
            ],
            "song":[
                {"id":"t1","albumId":"al1","artistId":"ar1","title":"Airbag","track":1,"duration":228}
            ]
        }}}
        """
        MockURLProtocolHandler.responseQueue = [.init(json: json)]

        let results = try await api.search3(query: "radio")

        XCTAssertEqual(results.artists.count, 1)
        XCTAssertEqual(results.artists[0].id, "ar1")
        XCTAssertEqual(results.artists[0].name, "Radiohead")
        XCTAssertEqual(results.artists[0].albumCount, 9)

        XCTAssertEqual(results.albums.count, 1)
        XCTAssertEqual(results.albums[0].id, "al1")
        XCTAssertEqual(results.albums[0].title, "OK Computer")
        XCTAssertEqual(results.albums[0].trackCount, 12)
        XCTAssertEqual(results.albums[0].year, 1997)

        XCTAssertEqual(results.songs.count, 1)
        XCTAssertEqual(results.songs[0].id, "t1")
        XCTAssertEqual(results.songs[0].title, "Airbag")
        XCTAssertEqual(results.songs[0].trackNumber, 1)
        XCTAssertEqual(results.songs[0].duration, 228)
    }

    /// Album title/name duality: "name" field (list context) resolves correctly.
    func testSearch3AlbumDecodesNameFieldAsTitle() async throws {
        let json = """
        {"subsonic-response":{"status":"ok","version":"1.16.1","searchResult3":{
            "album":[
                {"id":"al2","artistId":"ar2","name":"Kid A","songCount":10,"year":2000}
            ]
        }}}
        """
        MockURLProtocolHandler.responseQueue = [.init(json: json)]

        let results = try await api.search3(query: "kid")

        XCTAssertEqual(results.albums.count, 1)
        XCTAssertEqual(results.albums[0].title, "Kid A",
                       "album.name field must resolve as the album title via SubsonicAlbumDTO")
    }

    /// Missing arrays (only songs present): absent artist and album keys decode to [].
    func testSearch3OnlySongsPresentAbsentArraysDecodeToEmpty() async throws {
        let json = """
        {"subsonic-response":{"status":"ok","version":"1.16.1","searchResult3":{
            "song":[
                {"id":"s1","albumId":"al1","artistId":"ar1","title":"Paranoid Android","track":2,"duration":387}
            ]
        }}}
        """
        MockURLProtocolHandler.responseQueue = [.init(json: json)]

        let results = try await api.search3(query: "paranoid")

        XCTAssertTrue(results.artists.isEmpty, "absent 'artist' key must decode to []")
        XCTAssertTrue(results.albums.isEmpty,  "absent 'album' key must decode to []")
        XCTAssertEqual(results.songs.count, 1)
        XCTAssertEqual(results.songs[0].trackNumber, 2)
    }

    /// All-empty searchResult3 wrapper (no matches) → all three arrays empty, no throw.
    func testSearch3EmptySearchResult3ReturnsEmptyArraysNoThrow() async throws {
        let json = """
        {"subsonic-response":{"status":"ok","version":"1.16.1","searchResult3":{}}}
        """
        MockURLProtocolHandler.responseQueue = [.init(json: json)]

        let results = try await api.search3(query: "xyzzy-no-match")

        XCTAssertTrue(results.artists.isEmpty)
        XCTAssertTrue(results.albums.isEmpty)
        XCTAssertTrue(results.songs.isEmpty)
    }

    /// URL must include query, count params, and Subsonic auth query items.
    func testSearch3RequestURLContainsQueryCountsAndAuth() async throws {
        let json = """
        {"subsonic-response":{"status":"ok","version":"1.16.1","searchResult3":{}}}
        """
        MockURLProtocolHandler.responseQueue = [.init(json: json)]

        _ = try await api.search3(
            query: "beatles",
            artistCount: 5,
            albumCount: 10,
            songCount: 15,
            artistOffset: 1,
            albumOffset: 2,
            songOffset: 3
        )

        let captured = MockURLProtocolHandler.capturedRequests.first
        XCTAssertNotNil(captured)
        let items = URLComponents(string: captured?.url?.absoluteString ?? "")?.queryItems ?? []
        func q(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }

        // Endpoint path
        XCTAssertEqual(captured?.url?.path, "/rest/search3.view")

        // Search params
        XCTAssertEqual(q("query"),        "beatles")
        XCTAssertEqual(q("artistCount"),  "5")
        XCTAssertEqual(q("albumCount"),   "10")
        XCTAssertEqual(q("songCount"),    "15")
        XCTAssertEqual(q("artistOffset"), "1")
        XCTAssertEqual(q("albumOffset"),  "2")
        XCTAssertEqual(q("songOffset"),   "3")

        // Auth params
        XCTAssertEqual(q("u"), "alice")
        XCTAssertNotNil(q("t"), "token must be present")
        XCTAssertNotNil(q("s"), "salt must be present")
        XCTAssertEqual(q("c"), SubsonicAuth.clientName)
        XCTAssertEqual(q("v"), SubsonicAuth.apiVersion)
        XCTAssertEqual(q("f"), "json")
    }

    /// Blank/whitespace-only query returns empty results without a network call.
    func testSearch3BlankQueryReturnsEmptyWithoutNetworkCall() async throws {
        // No response queued — if the network were hit this would use an empty stub.
        // We verify no requests were captured.
        MockURLProtocolHandler.responseQueue = []

        let resultsEmpty     = try await api.search3(query: "")
        let resultsWhitespace = try await api.search3(query: "   ")

        XCTAssertTrue(resultsEmpty.artists.isEmpty)
        XCTAssertTrue(resultsEmpty.albums.isEmpty)
        XCTAssertTrue(resultsEmpty.songs.isEmpty)
        XCTAssertTrue(resultsWhitespace.artists.isEmpty)

        XCTAssertTrue(
            MockURLProtocolHandler.capturedRequests.isEmpty,
            "No network requests must be made for blank queries"
        )
    }

    /// updatedAt on search results is populated with a current epoch timestamp.
    func testSearch3UpdatedAtIsPopulated() async throws {
        let before = Int(Date().timeIntervalSince1970)
        let json = """
        {"subsonic-response":{"status":"ok","version":"1.16.1","searchResult3":{
            "song":[{"id":"s1","albumId":"al1","artistId":"ar1","title":"Song One"}]
        }}}
        """
        MockURLProtocolHandler.responseQueue = [.init(json: json)]

        let results = try await api.search3(query: "song")
        let after = Int(Date().timeIntervalSince1970)

        XCTAssertFalse(results.songs.isEmpty)
        let updatedAt = results.songs[0].updatedAt
        XCTAssertGreaterThanOrEqual(updatedAt, before, "updatedAt must be >= time before call")
        XCTAssertLessThanOrEqual(updatedAt, after,     "updatedAt must be <= time after call")
    }

    // MARK: - invalidURL guard

    func testFetchWithEmptyEndpointStillBuildsValidURL() async throws {
        // An empty endpoint produces "/rest/.view" which is still a valid URL.
        // The server would 404 but the URL construction itself should not throw .invalidURL.
        // We just verify buildURL doesn't return nil for an empty string.
        MockURLProtocolHandler.responseQueue = [
            .init(json: Fixtures.pingOK)
        ]
        // This may throw something else (notSubsonicServer, serverError) but NOT invalidURL.
        do {
            _ = try await api.fetch("", params: [:], as: GreetingPayload.self)
        } catch NavidromeAPI.APIError.invalidURL {
            XCTFail("Empty endpoint must not cause .invalidURL — URL construction should still succeed")
        } catch {
            // Any other error is acceptable here.
        }
    }
}
