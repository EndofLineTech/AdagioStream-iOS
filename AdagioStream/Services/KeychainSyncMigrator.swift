import AdagioStreamCore
import Foundation
import Security
import os.log

/// Migrates existing Keychain items (saved before 9nl.1) from the legacy
/// attribute set (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`,
/// `kSecAttrSynchronizable = false`) to the new iCloud-Keychain-syncable
/// attribute set (`kSecAttrAccessibleAfterFirstUnlock`,
/// `kSecAttrSynchronizable = true`).
///
/// Idempotency:
/// - A `UserDefaults` flag (`keychainSyncMigrationCompleted`) gates the
///   migration so it runs at most once successfully across app launches.
/// - Even if the flag is somehow not set, re-running the migration over
///   already-migrated items is a benign no-op (the scan returns zero
///   legacy items).
///
/// Failure semantics (non-fatal):
/// - If migration fails for any item, the original entry remains readable.
/// - The completion flag is NOT set on partial failures, so the next
///   launch retries.
/// - The app continues launching with whatever credentials are readable.
///
/// Atomicity strategy (per 9nl.2 description):
/// - First attempt: `SecItemUpdate` to change attributes in place. Atomic;
///   no data-loss window.
/// - Fallback: read the data, attempt an add of a new synchronizable item,
///   and only on successful add delete the legacy item. This ordering means
///   any failure leaves the legacy item readable.
/// - Real-device verification (whether `SecItemUpdate` actually propagates
///   the access-class transition to iCloud) is gated on bead 9nl.3 — a PO
///   action.
///
/// Observability:
/// - Per-item outcomes go to `os_log` under `com.adagiostream.app.migration`
///   so they surface in sysdiagnose.
/// - Counters are written to `MigrationDiagnostics` (UserDefaults-backed)
///   for the in-app Diagnostics screen.
@MainActor
enum KeychainSyncMigrator {
    private static let log = OSLog(subsystem: "com.adagiostream.app.migration", category: "keychain-sync")
    private static let service = "com.adagiostream.app"

    /// Known account names that the iOS app stores under the shared
    /// service. The migrator scans only these accounts; any item the app
    /// does not own remains untouched.
    private static let knownAccounts: [String] = [
        Constants.StorageKeys.providers
    ]

    /// Runs the migration if it has not already completed.
    /// Safe to call from `ProviderManager.init` before any Keychain read.
    static func runIfNeeded(
        diagnostics: MigrationDiagnostics = .shared
    ) {
        guard !diagnostics.migrationCompleted else {
            os_log("Migration already completed — skipping", log: log, type: .info)
            return
        }

        let candidates = scanLegacyItems()
        diagnostics.recordRunStart(itemsFound: candidates.count)

        if candidates.isEmpty {
            // Nothing to do — fresh install, or already migrated by a prior
            // run that didn't get to set the flag. Mark complete so we
            // short-circuit on subsequent launches.
            diagnostics.markMigrationCompleted()
            os_log("No legacy items found; marking migration complete", log: log, type: .info)
            return
        }

        var allSucceeded = true
        for account in candidates {
            let outcome = migrate(account: account)
            switch outcome {
            case .migrated:
                diagnostics.recordMigrated()
                os_log("Migrated account %{public}@", log: log, type: .info, account)
            case .skipped(let reason):
                diagnostics.recordSkipped()
                os_log("Skipped account %{public}@: %{public}@", log: log, type: .info, account, reason)
            case .failed(let reason):
                allSucceeded = false
                diagnostics.recordFailed("\(account): \(reason)")
                os_log("Failed to migrate account %{public}@: %{public}@",
                       log: log, type: .error, account, reason)
            }
        }

        if allSucceeded {
            diagnostics.markMigrationCompleted()
        }
    }

    // MARK: - Internals

    private enum Outcome {
        case migrated
        case skipped(String)
        case failed(String)
    }

    /// Returns the subset of `knownAccounts` that have a legacy
    /// (non-synchronizable) Keychain entry.
    private static func scanLegacyItems() -> [String] {
        knownAccounts.filter { account in
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecAttrSynchronizable as String: false,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecReturnAttributes as String: true,
            ]
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return status == errSecSuccess
        }
    }

    /// Migrates one account from legacy to synchronizable attributes.
    /// First attempts `SecItemUpdate` (atomic). On failure, falls back to
    /// add-new-then-delete-old; if the add fails, the legacy entry is left
    /// in place and the outcome is `.failed`.
    private static func migrate(account: String) -> Outcome {
        // Try in-place attribute update first.
        if updateInPlace(account: account) {
            return .migrated
        }

        // Fallback: read legacy data, add new synchronizable item, then
        // delete the legacy item. Order matters — the delete only runs
        // after a successful add, so on failure the legacy entry persists.
        guard let data = readLegacyData(account: account) else {
            return .failed("could not read legacy item")
        }

        if addSynchronizable(data: data, account: account) {
            deleteLegacy(account: account)
            return .migrated
        }

        return .failed("add of synchronizable item failed")
    }

    private static func updateInPlace(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
        let attributes: [String: Any] = [
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        return status == errSecSuccess
    }

    private static func readLegacyData(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func addSynchronizable(data: Data, account: String) -> Bool {
        // Pre-clear any existing synchronizable item under this account so
        // the add doesn't fail with errSecDuplicateItem.
        let preDelete: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
        ]
        SecItemDelete(preDelete as CFDictionary)

        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
        ]
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    private static func deleteLegacy(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
