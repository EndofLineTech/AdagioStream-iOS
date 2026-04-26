import Foundation
import Security

/// Wrapper around the iOS Keychain for storing provider credentials.
///
/// Items are written with `kSecAttrAccessibleAfterFirstUnlock` and
/// `kSecAttrSynchronizable = true` so iCloud Keychain syncs them across the
/// user's Apple-ID-paired devices (including the future tvOS app). Reads
/// and deletes use `kSecAttrSynchronizableAny` so the post-migration app
/// sees both legacy local-only items AND iCloud-synced items. Without
/// `Any` on the read side, the app silently misses iCloud-synced items
/// and signs the user out on a fresh install.
///
/// The service identifier (`com.adagiostream.app`) is byte-identical
/// across the iOS and future tvOS apps, despite the tvOS bundle ID being
/// `com.adagiostream.tv`. iCloud Keychain matches on
/// service+account+access-group, not bundle ID.
enum KeychainService {
    private static let service = "com.adagiostream.app"

    /// Saves `data` under `key`, replacing any existing entry. Items are
    /// marked synchronizable so iCloud Keychain propagates them.
    static func save(_ data: Data, for key: String) throws {
        // Delete BOTH local and iCloud-synced variants so we don't end up
        // with a stale legacy item shadowing the new synchronizable one.
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

    /// Loads the data stored under `key`, returning `nil` if no item exists
    /// or the read fails. The query uses
    /// `kSecAttrSynchronizable = kSecAttrSynchronizableAny` so iCloud-synced
    /// items written by another device are found alongside legacy local-only
    /// items.
    static func load(for key: String) -> Data? {
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

    /// Deletes the item stored under `key`. Uses
    /// `kSecAttrSynchronizable = kSecAttrSynchronizableAny` so iCloud-synced
    /// copies are also removed; otherwise delete operations would leave
    /// orphaned synced items.
    static func delete(for key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        SecItemDelete(query as CFDictionary)
    }

    enum KeychainError: Error, LocalizedError {
        case saveFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .saveFailed(let status):
                return "Keychain save failed (status \(status))"
            }
        }
    }
}
