import Foundation
import os.log

/// On-device, local-only counter store for the iCloud Keychain attribute
/// migration (see 9nl.2). Backed by `UserDefaults.standard`.
///
/// No analytics, no telemetry, no network. The user can read these counters
/// inside Settings → Diagnostics (`DiagnosticsView`) and may copy them to
/// the clipboard to voluntarily share with support.
///
/// Counters are written by the migration code path the first time it runs
/// (idempotency flag: `keychainSyncMigrationCompleted`), and remain readable
/// after the migration completes so users can verify what happened.
@MainActor
final class MigrationDiagnostics: ObservableObject {
    static let shared = MigrationDiagnostics()

    private let log = OSLog(subsystem: "com.adagiostream.app", category: "MigrationDiagnostics")
    private let defaults: UserDefaults

    // Storage keys — versioned to allow future migrations to extend without
    // colliding. Do NOT rename these without a follow-up migration.
    private enum DefaultsKey {
        static let itemsFound = "diagnostics.keychainSync.itemsFound"
        static let itemsMigrated = "diagnostics.keychainSync.itemsMigrated"
        static let itemsFailed = "diagnostics.keychainSync.itemsFailed"
        static let itemsSkipped = "diagnostics.keychainSync.itemsSkipped"
        static let lastRun = "diagnostics.keychainSync.lastRun"
        static let migrationCompleted = "keychainSyncMigrationCompleted"
        static let lastError = "diagnostics.keychainSync.lastError"
    }

    @Published private(set) var snapshot: Snapshot

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.snapshot = Self.loadSnapshot(from: defaults)
    }

    /// Local on-device snapshot of the migration counters. All fields are
    /// derived from `UserDefaults`; nothing leaves the device.
    struct Snapshot: Equatable {
        var itemsFound: Int
        var itemsMigrated: Int
        var itemsFailed: Int
        var itemsSkipped: Int
        var lastRun: Date?
        var migrationCompleted: Bool
        var lastError: String?
    }

    /// True once the migration has run to completion at least once.
    /// Used by the migration entry point as an idempotency gate.
    var migrationCompleted: Bool {
        defaults.bool(forKey: DefaultsKey.migrationCompleted)
    }

    /// Mark the migration as completed. Called by `9nl.2` after a successful
    /// run. Subsequent app launches will short-circuit the migration path.
    func markMigrationCompleted() {
        defaults.set(true, forKey: DefaultsKey.migrationCompleted)
        refresh()
    }

    /// Records the start of a migration run, resetting the counters.
    /// Idempotent: callable multiple times across app launches if the
    /// migration must retry (e.g., after a partial failure).
    func recordRunStart(itemsFound: Int) {
        defaults.set(itemsFound, forKey: DefaultsKey.itemsFound)
        defaults.set(0, forKey: DefaultsKey.itemsMigrated)
        defaults.set(0, forKey: DefaultsKey.itemsFailed)
        defaults.set(0, forKey: DefaultsKey.itemsSkipped)
        defaults.set(Date(), forKey: DefaultsKey.lastRun)
        defaults.removeObject(forKey: DefaultsKey.lastError)
        os_log("Migration run started: %d item(s) found", log: log, type: .info, itemsFound)
        refresh()
    }

    /// Increments the migrated counter — one item moved to the new attribute set.
    func recordMigrated() {
        increment(DefaultsKey.itemsMigrated)
    }

    /// Increments the failed counter — one item could not be migrated.
    /// `reason` is recorded to `os_log` and the most-recent failure is
    /// surfaced in the Diagnostics screen.
    func recordFailed(_ reason: String) {
        increment(DefaultsKey.itemsFailed)
        defaults.set(reason, forKey: DefaultsKey.lastError)
        os_log("Migration item failed: %{public}@", log: log, type: .error, reason)
        refresh()
    }

    /// Increments the skipped counter — item was already in the new attribute
    /// set, or otherwise didn't need to migrate.
    func recordSkipped() {
        increment(DefaultsKey.itemsSkipped)
    }

    /// Re-reads the snapshot from `UserDefaults`. Internal — used to refresh
    /// `@Published` state for SwiftUI consumers after counter mutations.
    private func refresh() {
        snapshot = Self.loadSnapshot(from: defaults)
    }

    private func increment(_ key: String) {
        let current = defaults.integer(forKey: key)
        defaults.set(current + 1, forKey: key)
        refresh()
    }

    private static func loadSnapshot(from defaults: UserDefaults) -> Snapshot {
        Snapshot(
            itemsFound: defaults.integer(forKey: DefaultsKey.itemsFound),
            itemsMigrated: defaults.integer(forKey: DefaultsKey.itemsMigrated),
            itemsFailed: defaults.integer(forKey: DefaultsKey.itemsFailed),
            itemsSkipped: defaults.integer(forKey: DefaultsKey.itemsSkipped),
            lastRun: defaults.object(forKey: DefaultsKey.lastRun) as? Date,
            migrationCompleted: defaults.bool(forKey: DefaultsKey.migrationCompleted),
            lastError: defaults.string(forKey: DefaultsKey.lastError)
        )
    }
}
