import AuthenticationServices
import Foundation

/// Drives the ABS OpenID sign-in end to end on iOS: PKCE → authorization URL →
/// `ASWebAuthenticationSession` → parse `adagiostream://oauth?code=&state=` →
/// token exchange. Returns the first `{accessToken, refreshToken}` pair for the
/// caller to persist via `AudiobookshelfAuth`.
///
/// iOS-only (imports `AuthenticationServices`); lives under `Views/` so the
/// tvOS target — which excludes `Views/` — never compiles it.
@MainActor
final class AudiobookshelfOIDCSession: NSObject, ASWebAuthenticationPresentationContextProviding {

    enum SignInError: Error, LocalizedError {
        case cancelled
        case missingCallbackParams
        case stateMismatch
        case flow(Error)

        var errorDescription: String? {
            switch self {
            case .cancelled: return "Sign-in was cancelled."
            case .missingCallbackParams: return "The sign-in response was incomplete. Try again."
            case .stateMismatch: return "The sign-in response could not be verified. Please try again."
            case .flow(let e): return (e as? LocalizedError)?.errorDescription ?? e.localizedDescription
            }
        }
    }

    /// Held for the lifetime of the presentation so ARC doesn't tear it down.
    private var webSession: ASWebAuthenticationSession?

    /// Runs the full flow. On success returns the token pair; throws
    /// `SignInError.cancelled` if the user dismisses the browser.
    func signIn(host: URL) async throws -> AudiobookshelfAuth.Tokens {
        let pkce = AudiobookshelfOIDC.makePKCE()
        let expectedState = AudiobookshelfOIDC.makeState()
        // ONE session shared across authorizationURL + exchange for the cookie jar.
        let flowSession = AudiobookshelfOIDC.makeFlowSession()

        let authURL: URL
        do {
            authURL = try await AudiobookshelfOIDC.authorizationURL(
                host: host, challenge: pkce.challenge, state: expectedState, session: flowSession
            )
        } catch {
            throw SignInError.flow(error)
        }

        let callbackURL = try await presentWebSession(authURL: authURL)

        // CSRF guard: reject an injected code whose state doesn't match ours,
        // BEFORE exchanging. The custom scheme is app-wide — anyone can invoke
        // adagiostream://oauth?code=…&state=…; only our own state proves the
        // callback answers our request.
        guard let callback = AudiobookshelfOIDC.validatedCallback(callbackURL, expectedState: expectedState) else {
            throw SignInError.stateMismatch
        }

        do {
            return try await AudiobookshelfOIDC.exchange(
                host: host, state: callback.state, code: callback.code, verifier: pkce.verifier, session: flowSession
            )
        } catch {
            throw SignInError.flow(error)
        }
    }

    /// Presents `ASWebAuthenticationSession` and resumes with the captured
    /// `adagiostream://oauth` callback URL. `prefersEphemeralWebBrowserSession`
    /// keeps the IdP cookies out of the shared Safari session.
    private func presentWebSession(authURL: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: AudiobookshelfOIDC.callbackScheme
            ) { callbackURL, error in
                if let error {
                    if let asError = error as? ASWebAuthenticationSessionError,
                       asError.code == .canceledLogin {
                        continuation.resume(throwing: SignInError.cancelled)
                    } else {
                        continuation.resume(throwing: SignInError.flow(error))
                    }
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: SignInError.missingCallbackParams)
                    return
                }
                continuation.resume(returning: callbackURL)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            self.webSession = session
            if !session.start() {
                continuation.resume(throwing: SignInError.cancelled)
            }
        }
    }

    // MARK: - ASWebAuthenticationPresentationContextProviding

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // Foreground key window; falls back to a fresh anchor if none is found.
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        return scene?.keyWindow ?? ASPresentationAnchor()
    }
}
