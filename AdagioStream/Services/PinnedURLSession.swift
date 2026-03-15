import Foundation

/// Provides pre-configured URLSessions for API domains.
///
/// ATS (App Transport Security) enforces TLS certificate validation.
/// These sessions add domain-specific configuration (timeouts, headers).
enum PinnedURLSession {
    /// Session for xmplaylist.com API calls.
    static let xmplaylist: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.httpAdditionalHeaders = ["User-Agent": "AdagioStream/1.0"]
        return URLSession(configuration: config)
    }()

    /// Session for ESPN API calls.
    static let espn: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()

    /// Session for iTunes Search API calls.
    static let itunes: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()
}
