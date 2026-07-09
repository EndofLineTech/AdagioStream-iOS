import Foundation

/// A user-configured stream provider (M3U URL or Xtream Codes account).
/// Persisted to the iOS Keychain under
/// `Constants.StorageKeys.providers` (encoded as JSON).
public struct Provider: Codable, Identifiable {
    public let id: UUID
    public var name: String
    public var type: ProviderType
    public var isEnabled: Bool
    public var stripStreamIDs: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        type: ProviderType,
        isEnabled: Bool = true,
        stripStreamIDs: Bool = false
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.isEnabled = isEnabled
        self.stripStreamIDs = stripStreamIDs
    }

    /// Tolerant decoder — `isEnabled` and `stripStreamIDs` default when
    /// missing so older on-disk data still loads.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(ProviderType.self, forKey: .type)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        stripStreamIDs = try container.decodeIfPresent(Bool.self, forKey: .stripStreamIDs) ?? false
    }

    /// Discriminator for the supported provider integrations.
    public enum ProviderType: Codable, Hashable {
        case m3u(url: URL, epgURL: URL?)
        case xtreamCodes(host: URL, username: String, password: String)
        case subsonic(host: URL, username: String, password: String)
        case audiobookshelf(host: URL, username: String, password: String)
    }
}

public extension Provider.ProviderType {
    /// An Audiobookshelf provider authenticated via OpenID/SSO rather than a
    /// password. Represented as an ABS case with an empty username+password —
    /// the access/refresh tokens live in the Keychain (seeded by the OIDC flow),
    /// so no credentials are stored. Lets validation skip the password `login()`
    /// path and rely on the pre-seeded tokens instead.
    // ponytail: empty-cred marker — no enum change. Ceiling: a password-authed
    // ABS provider can't have empty username+password anyway (form validation
    // requires both), so the two never collide. Upgrade to an explicit
    // `authMode` field on the ABS case only if that invariant ever loosens.
    var isAudiobookshelfOIDC: Bool {
        if case .audiobookshelf(_, let username, let password) = self {
            return username.isEmpty && password.isEmpty
        }
        return false
    }
}
