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
