import CryptoKit
import Foundation

/// Provides URLSessions with certificate pinning for first-party API domains.
///
/// Pins intermediate CA public keys (SPKI SHA-256 hashes) for known domains.
/// Intermediate CA pins are more stable than leaf pins — they survive cert
/// renewals and typically last 3-5 years.
enum PinnedURLSession {
    // MARK: - Pin Database

    /// SPKI SHA-256 hashes of pinned intermediate CA certificates, keyed by domain.
    /// Each domain should have at least the current intermediate plus a backup.
    private static let pins: [String: Set<String>] = [
        // Google Trust Services WE1 (xmplaylist.com intermediate)
        // Issuer: GTS Root R4 → GlobalSign Root CA
        "xmplaylist.com": [
            "kIdp6NNEd8wsugYyyIYFsi1ylMCED3hZbSR8ZFsa/A4=",
        ],
        // Apple Public EV Server RSA CA 1 - G1 (itunes.apple.com intermediate)
        // Issuer: DigiCert Global Root G2
        "itunes.apple.com": [
            "9C7mf4J789KvLX59lcMyYpsH6bpdmoAGTByZNhcusLA=",
        ],
    ]

    // MARK: - Shared Sessions

    /// Pinned session for xmplaylist.com API calls.
    static let xmplaylist: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.httpAdditionalHeaders = ["User-Agent": "AdagioStream/1.0"]
        return URLSession(configuration: config, delegate: PinningDelegate(), delegateQueue: nil)
    }()

    /// Pinned session for iTunes Search API calls.
    static let itunes: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config, delegate: PinningDelegate(), delegateQueue: nil)
    }()

    // MARK: - Validation

    /// Check whether any certificate in the server's chain matches a pinned SPKI hash for the given domain.
    static func validate(serverTrust: SecTrust, for domain: String) -> Bool {
        guard let expectedPins = pins[domain], !expectedPins.isEmpty else {
            // No pins configured for this domain — allow (ATS still enforces TLS)
            return true
        }

        let certCount = SecTrustGetCertificateCount(serverTrust)
        for index in 0..<certCount {
            guard let cert = SecTrustCopyCertificateChain(serverTrust).map({ ($0 as [AnyObject])[index] }) as! SecCertificate? else {
                continue
            }
            if let spkiHash = spkiSHA256(of: cert), expectedPins.contains(spkiHash) {
                return true
            }
        }

        DebugLogger.shared.log("Certificate pinning FAILED for \(domain) — no matching pin in chain of \(certCount) certs", category: .general)
        return false
    }

    /// Compute the Base64-encoded SHA-256 hash of a certificate's Subject Public Key Info (SPKI).
    private static func spkiSHA256(of certificate: SecCertificate) -> String? {
        guard let publicKey = SecCertificateCopyKey(certificate) else { return nil }
        var error: Unmanaged<CFError>?
        guard let keyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else { return nil }
        let hash = SHA256.hash(data: keyData)
        return Data(hash).base64EncodedString()
    }
}

// MARK: - URLSession Delegate

private final class PinningDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let host = challenge.protectionSpace.host
        if PinnedURLSession.validate(serverTrust: serverTrust, for: host) {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
