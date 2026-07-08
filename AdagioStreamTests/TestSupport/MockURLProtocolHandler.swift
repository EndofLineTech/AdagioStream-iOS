// t96.24 — Shared network-stub harness.
//
// Originally defined in NavidromeAPITests.swift but consumed by
// NavidromeLibraryViewModelTests and XtreamCodesAPITests too; moved to
// TestSupport since it's a cross-file dependency, not a private helper.

import XCTest

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
