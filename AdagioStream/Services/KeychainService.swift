import Foundation
import Security

/// Wrapper around the iOS Keychain for storing provider credentials.
///
/// Items are written with `kSecAttrAccessibleAfterFirstUnlock` and
/// `kSecAttrSynchronizable = true` so iCloud Keychain syncs them across the
/// user's Apple-ID-paired devices (including the tvOS app). Reads and
/// deletes use `kSecAttrSynchronizableAny` so the post-migration app sees
/// both legacy local-only items AND iCloud-synced items. Without `Any` on
/// the read side, the app silently misses iCloud-synced items and signs
/// the user out on a fresh install.
///
/// The service identifier (`com.adagiostream.app`) is byte-identical
/// across the iOS and tvOS apps, despite the tvOS bundle ID being
/// `com.adagiostream.tv`. iCloud Keychain matches on
/// service+account+access-group, not bundle ID. Tests may pass a unique
/// service id (e.g., `com.adagiostream.app.tests`) to the underscore-
/// prefixed `_*` overloads so they never touch production-keyed entries.
public enum KeychainService {
    /// The production service identifier. Locked byte-identical across
    /// platforms — renaming it orphans existing user data.
    public static let productionService = "com.adagiostream.app"

    /// Saves `data` under `key`, replacing any existing entry. Items are
    /// marked synchronizable so iCloud Keychain propagates them.
    public static func save(_ data: Data, for key: String) throws {
        try _save(data, for: key, service: productionService)
    }

    /// Loads the data stored under `key`, returning `nil` if no item
    /// exists or the read fails. Uses
    /// `kSecAttrSynchronizable = kSecAttrSynchronizableAny` so iCloud
    /// synced items written by another device are found alongside legacy
    /// local-only items.
    public static func load(for key: String) -> Data? {
        _load(for: key, service: productionService)
    }

    /// Deletes the item stored under `key`. Uses
    /// `kSecAttrSynchronizable = kSecAttrSynchronizableAny` so iCloud
    /// synced copies are also removed; otherwise delete operations would
    /// leave orphaned synced items.
    public static func delete(for key: String) {
        _delete(for: key, service: productionService)
    }

    // MARK: - Service-parameterized variants (tests + migrator)

    /// Save under an arbitrary service id. Used by tests with a unique
    /// `com.adagiostream.app.tests` identifier, and by the keychain
    /// migrator for in-place attribute updates.
    public static func _save(_ data: Data, for key: String, service: String) throws {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    /// Load under an arbitrary service id. See `_save`.
    public static func _load(for key: String, service: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    /// Delete under an arbitrary service id. See `_save`.
    public static func _delete(for key: String, service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        SecItemDelete(query as CFDictionary)
    }

    public enum KeychainError: Error, LocalizedError {
        case saveFailed(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .saveFailed(let status):
                return "Keychain save failed (status \(status))"
            }
        }
    }
}
