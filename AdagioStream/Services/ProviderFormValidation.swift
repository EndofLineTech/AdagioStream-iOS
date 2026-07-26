import Foundation

/// Pure, testable validation for the credential forms (beads_mobilemusic-uxb.3).
///
/// AddProviderView and WelcomeSetupView each had their own copy of the same
/// per-provider-type validation, gating a disabled Save/Add button with no
/// per-field feedback. This is the single decision function both views call,
/// so the truth table (which field is missing/invalid for which provider
/// type) is unit-tested without any SwiftUI dependency, and both views stay
/// in sync automatically.
enum ProviderFormValidation {

    /// The provider types that share the name + host + username/password
    /// shape. M3U has no username/password.
    enum ProviderKind {
        case m3u
        case xtreamCodes
        case subsonic
        case audiobookshelf
    }

    /// Per-field error captions; `nil` means that field is valid.
    struct Result: Equatable {
        var name: String?
        var host: String?
        var username: String?
        var password: String?

        var isValid: Bool {
            name == nil && host == nil && username == nil && password == nil
        }
    }

    static let allowedURLSchemes: Set<String> = ["http", "https"]

    static func validate(
        kind: ProviderKind,
        name: String,
        host: String,
        username: String,
        password: String
    ) -> Result {
        var result = Result()

        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            result.name = "Name is required"
        }

        if !isValidURL(host, allowedSchemes: allowedURLSchemes) {
            result.host = "Enter a valid URL (http/https)"
        }

        switch kind {
        case .m3u:
            break
        case .xtreamCodes, .subsonic, .audiobookshelf:
            if username.isEmpty { result.username = "Username is required" }
            if password.isEmpty { result.password = "Password is required" }
        }

        return result
    }

    /// True when `string` parses as a URL whose scheme (case-insensitive) is
    /// in `allowedSchemes`.
    static func isValidURL(_ string: String, allowedSchemes: Set<String>) -> Bool {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased() else { return false }
        return allowedSchemes.contains(scheme)
    }

    // MARK: - AddManualEntryView (different field shape, same URL-validation core)

    /// beads_mobilemusic-uxb.3: AddManualEntryView's stream-URL scheme
    /// allowlist is wider than the server forms (custom streams can be RTSP/
    /// RTMP/MMS, not just HTTP/HTTPS) and it rejected a bad scheme silently.
    static let manualEntryAllowedSchemes: Set<String> = ["http", "https", "rtsp", "rtmp", "mms"]

    struct ManualEntryResult: Equatable {
        var name: String?
        var url: String?
        var group: String?

        var isValid: Bool { name == nil && url == nil && group == nil }
    }

    static func validateManualEntry(name: String, url: String, hasGroup: Bool) -> ManualEntryResult {
        var result = ManualEntryResult()

        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            result.name = "Name is required"
        }

        let trimmedURL = url.trimmingCharacters(in: .whitespaces)
        if trimmedURL.isEmpty {
            result.url = "Stream URL is required"
        } else if !isValidURL(trimmedURL, allowedSchemes: manualEntryAllowedSchemes) {
            result.url = "Enter a valid URL (http/https/rtsp/rtmp/mms)"
        }

        if !hasGroup {
            result.group = "Choose a group"
        }

        return result
    }
}
