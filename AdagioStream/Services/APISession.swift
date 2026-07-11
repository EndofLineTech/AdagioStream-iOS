import Foundation

/// Provides pre-configured URLSessions for the app's hardcoded API domains.
///
/// TLS enforcement is handled by ATS (App Transport Security) via the
/// NSExceptionDomains entries in Info.plist; this type does NOT perform
/// certificate pinning. Each static property returns a URLSession with
/// domain-specific configuration (timeout, custom headers).
public enum APISession {
    /// Session for xmplaylist.com API calls.
    public static let xmplaylist: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.httpAdditionalHeaders = ["User-Agent": "AdagioStream/1.0"]
        return URLSession(configuration: config)
    }()

    /// Session for api.stellartunerlog.com API calls.
    public static let stellartunerlog: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.httpAdditionalHeaders = ["User-Agent": "AdagioStream/1.0"]
        return URLSession(configuration: config)
    }()

    /// Session for ESPN API calls.
    public static let espn: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()

    /// Session for iTunes Search API calls.
    public static let itunes: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()
}
