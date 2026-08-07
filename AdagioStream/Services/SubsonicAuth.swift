import Foundation
import CryptoKit

/// Builds Subsonic REST API authentication query parameters using token auth.
///
/// Token auth is the only mode implemented. Legacy `p=enc` (plain/hex-encoded password)
/// is intentionally omitted — deferred to bead a6f.12 per PO decision.
///
/// The Subsonic protocol spec requires MD5 for token computation. `Insecure.MD5` is
/// used here not for security but for spec compliance: the server verifies
/// `t == MD5(password + salt)`. There is no alternative within the Subsonic protocol.
public struct SubsonicAuth {

    // MARK: - Constants

    /// Client identifier sent as the `c` parameter in every Subsonic request.
    public static let clientName = "AdagioStream"

    /// Subsonic REST API version sent as the `v` parameter.
    public static let apiVersion = "1.16.1"

    // MARK: - Stored properties

    public let username: String
    private let password: String

    // MARK: - Init

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    // MARK: - Auth params

    /// Returns the six Subsonic authentication query parameters.
    ///
    /// - Parameter salt: Optional salt for deterministic testing. When `nil` a
    ///   cryptographically-secure random salt (≥ 8 bytes) is generated automatically.
    ///   Production callers should always pass `nil`.
    /// - Returns: `[u, t, s, c, v, f]` as `URLQueryItem` values ready to append to
    ///   a `URLComponents` query.
    public func queryItems(salt: String? = nil) -> [URLQueryItem] {
        let resolvedSalt = salt ?? Self.generateSalt()
        let token = Self.md5Token(password: password, salt: resolvedSalt)

        return [
            URLQueryItem(name: "u", value: username),
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "s", value: resolvedSalt),
            URLQueryItem(name: "c", value: Self.clientName),
            URLQueryItem(name: "v", value: Self.apiVersion),
            URLQueryItem(name: "f", value: "json"),
        ]
    }

    // MARK: - Private helpers

    /// Computes `MD5(password + salt)` as a lowercase hex string.
    ///
    /// `Insecure.MD5` is REQUIRED by the Subsonic protocol spec — this is not a
    /// security choice but a protocol compliance requirement. The server side
    /// verifies `t == MD5(password + salt)`.
    static func md5Token(password: String, salt: String) -> String {
        let input = Data((password + salt).utf8)
        let digest = Insecure.MD5.hash(data: input)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Generates a cryptographically-secure random salt encoded as a hex string.
    /// Minimum 8 bytes (16 hex characters). Uses `SystemRandomNumberGenerator`,
    /// which is backed by `SecRandomCopyBytes` on Apple platforms.
    private static func generateSalt(byteCount: Int = 12) -> String {
        var rng = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: byteCount)
        for i in bytes.indices {
            bytes[i] = UInt8.random(in: 0...255, using: &rng)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - CustomStringConvertible / CustomDebugStringConvertible

extension SubsonicAuth: CustomStringConvertible {
    /// The password is intentionally excluded to prevent accidental log exposure.
    public var description: String {
        "SubsonicAuth(username: \(username))"
    }
}

extension SubsonicAuth: CustomDebugStringConvertible {
    /// The password is intentionally excluded to prevent accidental log exposure.
    public var debugDescription: String {
        "SubsonicAuth(username: \(username), password: <redacted>)"
    }
}
