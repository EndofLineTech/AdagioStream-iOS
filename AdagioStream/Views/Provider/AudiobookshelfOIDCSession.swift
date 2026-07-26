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
        let sessionCookies: [HTTPCookie]
        do {
            (authURL, sessionCookies) = try await AudiobookshelfOIDC.authorizationURL(
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
                host: host, state: callback.state, code: callback.code, verifier: pkce.verifier,
                cookies: sessionCookies, session: flowSession
            )
        } catch {
            throw SignInError.flow(error)
        }
    }

    /// Presents `ASWebAuthenticationSession` and resumes with the captured
    /// `adagiostream://oauth` callback URL. `prefersEphemeralWebBrowserSession`
    /// keeps the IdP cookies out of the shared Safari session.
    ///
    /// beads_mobilemusic-uxb kickback finding 1: wrapped in
    /// `withTaskCancellationHandler` so cancelling the owning `Task` (the
    /// sheet was dismissed / Cancel tapped) reaches the system browser sheet
    /// via `session.cancel()` instead of leaving it presented with no parent.
    /// `ASWebAuthenticationSession.cancel()` synchronously invokes the
    /// completion handler with `.canceledLogin` on the main thread, so the
    /// continuation still resumes exactly once from that single completion
    /// callback — the cancellation handler only triggers the system cancel,
    /// it never resumes the continuation itself. That path already maps to
    /// `SignInError.cancelled`, so the caller sees the same silent/benign
    /// cancellation as a user-initiated dismiss.
    private func presentWebSession(authURL: URL) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // beads_mobilemusic-uxg: bail before constructing/starting the
                // session if the Task was already cancelled. Without this, an
                // already-cancelled Task racing session.start() returning
                // false (a documented ASWebAuthenticationSession failure
                // mode) could resume the continuation from two places —
                // whether the completion handler also fires in that case is
                // undocumented, so this removes the compound window entirely
                // rather than relying on it not happening.
                guard !Task.isCancelled else {
                    continuation.resume(throwing: SignInError.cancelled)
                    return
                }
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
        } onCancel: { [weak self] in
            // May run on an arbitrary thread; ASWebAuthenticationSession is
            // main-thread-only.
            Task { @MainActor in
                self?.webSession?.cancel()
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
