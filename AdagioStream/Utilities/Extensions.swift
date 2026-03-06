import Foundation
import SwiftUI

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

extension Date {
    var shortTimeString: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: self)
    }

    var mediumDateTimeString: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: self)
    }
}

extension String {
    /// Extracts a quoted attribute value from an M3U EXTINF line.
    /// e.g. `tvg-id="channel1"` → `"channel1"`
    func extractAttribute(_ key: String) -> String? {
        guard let range = range(of: "\(key)=\"") else { return nil }
        let start = range.upperBound
        guard let endRange = self[start...].range(of: "\"") else { return nil }
        return String(self[start..<endRange.lowerBound])
    }
}

extension URL {
    /// Returns a redacted version of this URL safe for logging.
    /// Strips Xtream Codes credentials from both path (`/live/user/pass/`) and query parameters.
    var redactedForLog: String {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return "***"
        }

        // Redact path credentials: /live/user/pass/id.ext → /live/***/***//id.ext
        if let path = components.path.range(of: #"^/live/[^/]+/[^/]+/"#, options: .regularExpression) {
            let remainder = components.path[path.upperBound...]
            components.path = "/live/***/***/\(remainder)"
        }

        // Redact hostname for Xtream Codes API paths
        if components.path.contains(Constants.XtreamCodes.apiPath) {
            components.host = "***"
        }

        // Redact query params
        components.queryItems = components.queryItems?.map { item in
            if item.name == "username" || item.name == "password" {
                return URLQueryItem(name: item.name, value: "***")
            }
            return item
        }

        return components.string ?? "***"
    }

    /// Builds an Xtream Codes API URL with the given action and optional extra parameters.
    func xtreamCodesURL(username: String, password: String, action: String, params: [String: String] = [:]) -> URL? {
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
