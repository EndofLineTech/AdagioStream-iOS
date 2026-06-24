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
