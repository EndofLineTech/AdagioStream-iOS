import Foundation

// MARK: - Networking

/// Shared retry-once-on-5xx-with-delay helper used by `XtreamCodesAPI` and
/// `NavidromeAPI`. Both clients hand-rolled the identical "sleep then retry
/// once" gate for transient server errors (beads_mobilemusic-t96.5); this is
/// only the byte-identical intent — each client still owns its own request
/// plumbing and error types.
enum RetryOnServerError {
    /// Returns `true` if the caller should retry: this is the first attempt
    /// and the status code is a 5xx. Callers are responsible for sleeping
    /// `delay` themselves before retrying (see `wait(_:)`).
    static func shouldRetry(attempt: Int, statusCode: Int) -> Bool {
        attempt == 1 && (500...599).contains(statusCode)
    }

    /// Sleeps for `delay` before a retry. Tests pass `.zero` to skip the wait.
    static func wait(_ delay: Duration) async {
        try? await Task.sleep(for: delay)
    }
}

// MARK: - Int (duration)

extension Int {
    /// Formats a track duration in seconds as `m:ss`, rolling over to
    /// `h:mm:ss` once the duration reaches an hour. Shared by all
    /// track-duration displays; see beads_mobilemusic-t96.2.
    public var durationString: String {
        let h = self / 3600
        let m = (self % 3600) / 60
        let s = self % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%d:%02d", m, s)
        }
    }
}

// MARK: - Date

extension Date {
    /// Locale-aware short time string (e.g. `"3:45 PM"`).
    public var shortTimeString: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: self)
    }

    /// Locale-aware medium-date + short-time string (e.g. `"Apr 25, 2026 at 3:45 PM"`).
    public var mediumDateTimeString: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: self)
    }
}

// MARK: - String

extension String {
    /// Extracts a quoted attribute value from an M3U `#EXTINF` line.
    /// e.g. `tvg-id="channel1"` → `"channel1"`. Returns `nil` if the
    /// attribute is missing or empty.
    public func extractAttribute(_ key: String) -> String? {
        guard let range = range(of: "\(key)=\"") else { return nil }
        let start = range.upperBound
        guard let endRange = self[start...].range(of: "\"") else { return nil }
        let value = String(self[start..<endRange.lowerBound])
        return value.isEmpty ? nil : value
    }
}

// MARK: - URL

extension URL {
    /// Returns a redacted version of this URL safe for logging.
    /// Strips Xtream Codes credentials from both path
    /// (`/live/user/pass/`) and query parameters, plus Subsonic's
    /// `u`/`p`/`t`/`s` auth query params — one helper covers both
    /// credential schemes (beads_mobilemusic-t96.6).
    public var redactedForLog: String {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return "***"
        }

        // Redact path credentials: /live/user/pass/id.ext → /live/***/***/id.ext
        if let path = components.path.range(of: #"^/live/[^/]+/[^/]+/"#, options: .regularExpression) {
            let remainder = components.path[path.upperBound...]
            components.path = "/live/***/***/\(remainder)"
        }

        // Redact hostname for Xtream Codes API paths
        if components.path.contains(Constants.XtreamCodes.apiPath) {
            components.host = "***"
        }

        // Redact query params (Xtream: username/password; Subsonic: u/p/t/s)
        let redactedParamNames: Set<String> = ["username", "password", "u", "p", "t", "s"]
        components.queryItems = components.queryItems?.map { item in
            if redactedParamNames.contains(item.name) {
                return URLQueryItem(name: item.name, value: "***")
            }
            return item
        }

        return components.string ?? "***"
    }

    /// Builds an Xtream Codes API URL with the given action and optional
    /// extra parameters layered onto the existing query string.
    public func xtreamCodesURL(
        username: String,
        password: String,
        action: String,
        params: [String: String] = [:]
    ) -> URL? {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        components?.path = Constants.XtreamCodes.apiPath
        var queryItems = [
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "password", value: password),
        ]
        if !action.isEmpty {
            queryItems.append(URLQueryItem(name: "action", value: action))
        }
        for (key, value) in params {
            queryItems.append(URLQueryItem(name: key, value: value))
        }
        components?.queryItems = queryItems
        return components?.url
    }
}
