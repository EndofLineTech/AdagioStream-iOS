import XCTest
import GRDB
@testable import AdagioStream

/// Unit tests for `NavidromeStore` using an in-memory `DatabaseQueue`.
///
/// File-protection assertions require an on-disk database and a real device/
/// simulator sandbox — they are omitted here and can be added as a separate
/// on-device test if needed.
final class NavidromeStoreTests: XCTestCase {

    // MARK: - Helpers

    /// Returns a fresh in-memory NavidromeStore with all migrations applied.
    private func makeStore() throws -> NavidromeStore {
        try makeInMemoryNavidromeStore()
    }

    // MARK: - Migration completeness

    /// All v1 + v2 + v4 + v5 tables exist after migration.
    func testMigrationsCreateAllTables() throws {
        let store = try makeStore()
        let tableNames = try store.writer.read { db -> [String] in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
            )
        }
        // grdb_migrations is the internal GRDB tracking table.
        let expected: Set<String> = [
            "artists", "albums", "tracks", "downloads",
            "audiobooks", "chapters", "audiobook_downloads", "grdb_migrations",
        ]
        XCTAssertEqual(Set(tableNames), expected,
                       "Expected tables \(expected), got \(tableNames)")
    }

    /// v1 indexes are present.
    func testV1IndexesExist() throws {
        let store = try makeStore()
        let indexNames = try store.writer.read { db -> [String] in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type='index' ORDER BY name"
            )
        }
        let expectedIndexes: Set<String> = [
            "idx_artists_name",
            "idx_artists_sortName",
            "idx_albums_artistId",
            "idx_albums_genre",
            "idx_albums_year",
            "idx_albums_title",
            "idx_tracks_albumId",
            "idx_tracks_artistId",
            "idx_tracks_genre",
            "idx_tracks_title",
        ]
        for idx in expectedIndexes {
            XCTAssertTrue(indexNames.contains(idx), "Missing index: \(idx)")
        }
    }

    /// v2 partial indexes are present.
    func testV2PartialIndexesExist() throws {
        let store = try makeStore()
        let indexNames = try store.writer.read { db -> [String] in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type='index' ORDER BY name"
            )
        }
        XCTAssertTrue(indexNames.contains("idx_downloads_active"),
                      "Missing idx_downloads_active")
        XCTAssertTrue(indexNames.contains("idx_downloads_localPath"),
                      "Missing idx_downloads_localPath")
    }

    /// tracks table has the `path` column.
    func testTracksTableHasPathColumn() throws {
        let store = try makeStore()
        let columns = try store.writer.read { db -> [String] in
            try db.columns(in: "tracks").map(\.name)
        }
        XCTAssertTrue(columns.contains("path"), "tracks table missing 'path' column")
    }

    // MARK: - Idempotency

    /// Running migrate() a second time on the same database does not throw.
    func testMigratorIsIdempotent() throws {
        let queue = try DatabaseQueue()
        // First migration — performed by init.
        let store = try NavidromeStore(writer: queue)
        // Second migration — must be a no-op.
        XCTAssertNoThrow(try NavidromeStore.migrator.migrate(store.writer),
                         "migrate() threw on second call — migrator is not idempotent")
    }

    // MARK: - CHECK constraint on downloads.status

    /// Inserting a row with a valid status succeeds.
    func testDownloadsValidStatusInserts() throws {
        let store = try makeStore()
        try store.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO downloads
                        (id, status, resumeOffset, createdAt, updatedAt)
                    VALUES (?, ?, 0, ?, ?)
                    """,
                arguments: ["dl-1", "queued", 1_700_000_000, 1_700_000_000]
            )
        }
        let count = try store.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM downloads")!
        }
        XCTAssertEqual(count, 1)
    }

    /// Inserting a row with an invalid status throws a `DatabaseError`.
    func testDownloadsInvalidStatusIsRejected() throws {
        let store = try makeStore()
        XCTAssertThrowsError(
            try store.writer.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO downloads
                            (id, status, resumeOffset, createdAt, updatedAt)
                        VALUES (?, ?, 0, ?, ?)
                        """,
                    arguments: ["dl-bad", "archived", 1_700_000_000, 1_700_000_000]
                )
            },
            "Expected DatabaseError for invalid status"
        ) { error in
            XCTAssertTrue(error is DatabaseError,
                          "Expected DatabaseError, got \(type(of: error))")
        }
    }
}
