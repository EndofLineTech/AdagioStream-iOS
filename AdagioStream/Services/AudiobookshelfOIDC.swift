import Foundation

/// Audiobookshelf OpenID Connect (SSO) support.
///
/// ABS fronts the identity provider (Google / Authentik / Authelia / …), so a
/// single PKCE authorization-code flow covers every backend. This type owns
/// only OBTAINING the first `{accessToken, refreshToken}` pair; once persisted
/// via `AudiobookshelfAuth`'s Keychain storage, all refresh/rotation/401-retry
/// is already handled there.
///
/// tvOS-safe: this file imports no iOS-only frameworks. The PKCE + code-exchange
/// networking lives in `AudiobookshelfOIDCFlow.swift` (also tvOS-safe); the
/// `ASWebAuthenticationSession` UI is iOS-only and lives under `Views/`.
public enum AudiobookshelfOIDC {

    // MARK: - Constants

    /// Custom URL scheme registered in project.yml (CFBundleURLTypes). The
    /// browser callback lands on `adagiostream://oauth`.
    public static let redirectURI = "adagiostream://oauth"
    public static let callbackScheme = "adagiostream"
    public static let clientID = "AdagioStream"

    // MARK: - Discovery (wv4.1)

    /// What `GET /status` tells us about a server's auth options. Drives whether
    /// the add-provider UI shows an SSO button and what to label it.
    public struct Discovery: Equatable {
        public var isInit: Bool
        public var supportsOpenID: Bool
        public var supportsLocal: Bool
        public var buttonText: String
        public var autoLaunch: Bool

        public init(isInit: Bool, supportsOpenID: Bool, supportsLocal: Bool = true, buttonText: String, autoLaunch: Bool) {
            self.isInit = isInit
            self.supportsOpenID = supportsOpenID
            self.supportsLocal = supportsLocal
            self.buttonText = buttonText
            self.autoLaunch = autoLaunch
        }
    }

    public enum OIDCError: Error, LocalizedError {
        case invalidURL
        case discoveryFailed(statusCode: Int)
        case authURLMissing
        case malformedResponse
        case network(Error)

        public var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid server URL."
            case .discoveryFailed(let code): return "Could not read server status (HTTP \(code))."
            case .authURLMissing: return "The server did not return a sign-in URL."
            case .malformedResponse: return "The server response was not in the expected format."
            case .network(let e): return "Cannot reach the server: \(e.localizedDescription)"
            }
        }
    }

    /// Raw `GET /status` payload. Only the auth-related fields are read.
    struct StatusResponse: Decodable {
        let isInit: Bool?
        let authMethods: [String]?
        let authFormData: AuthFormData?

        struct AuthFormData: Decodable {
            let authOpenIDButtonText: String?
            let authOpenIDAutoLaunch: Bool?
        }
    }

    /// Maps a decoded `/status` payload to `Discovery`. Pure — unit-tested.
    static func discovery(from status: StatusResponse) -> Discovery {
        let methods = status.authMethods ?? []
        let openid = methods.contains("openid")
        // Default to local=true when the server didn't send authMethods, so a
        // sparse/old response never hides the password fields.
        let local = methods.isEmpty ? true : methods.contains("local")
        let label = status.authFormData?.authOpenIDButtonText.flatMap { $0.isEmpty ? nil : $0 }
            ?? "Login with OpenID"
        return Discovery(
            isInit: status.isInit ?? true,
            supportsOpenID: openid,
            supportsLocal: local,
            buttonText: label,
            autoLaunch: status.authFormData?.authOpenIDAutoLaunch ?? false
        )
    }

    /// Unauthenticated `GET /status`. Returns whether OpenID is available and
    /// the server's button label. Subpath-safe via `AudiobookshelfURL.resolve`.
    public static func discover(host: URL, session: URLSession = .shared) async throws -> Discovery {
        guard let url = AudiobookshelfURL.resolve(host: host, path: "/status") else {
            throw OIDCError.invalidURL
        }
        // Short per-request timeout so a black-holed server surfaces as .failed
        // in ~8s instead of hanging the UI on URLSession's ~60s default. On the
        // request (not a session config) so it applies to any injected session
        // and doesn't touch the sign-in/exchange path.
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw OIDCError.network(error)
        }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw OIDCError.discoveryFailed(statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard let status = try? JSONDecoder().decode(StatusResponse.self, from: data) else {
            throw OIDCError.malformedResponse
        }
        return discovery(from: status)
    }
}
