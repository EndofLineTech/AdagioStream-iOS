// MARK: - Persistence Architecture
// JSON/PersistenceService handles provider config and app settings (filenames in
// Constants.StorageKeys). GRDB/SQLite (this file) handles the Navidrome library
// cache (artists, albums, tracks) and the download index; the two stores are
// intentionally separate per the spike 51a decision so a library-cache wipe
// cannot affect provider configuration or user preferences.

import Foundation
import GRDB

/// Wraps a GRDB database writer providing the Navidrome library-cache schema
/// (v1: artists/albums/tracks) and the download index (v2: downloads).
///
/// **Production** — use `NavidromeStore.shared`, which opens a `DatabasePool`
/// (concurrent reads + background sync writes) at the standard Application
/// Support path, with `.completeFileProtectionUntilFirstUserAuthentication` on
/// the SQLite file and its WAL sidecars.
///
/// **Tests** — inject an in-memory `DatabaseQueue` via `init(writer:)`:
/// ```swift
/// let store = try NavidromeStore(writer: DatabaseQueue())
/// ```
///
/// The store is intentionally thin — it owns schema + migrator only.  Typed
/// record structs (Artist, Album, Track, Download conforming to
/// FetchableRecord/PersistableRecord) are added in bead a6f.9.
public final class NavidromeStore {

    // MARK: - Shared production instance

    /// Production singleton backed by a `DatabasePool` at the standard path.
    /// Lazily initialised; throws are surfaced as `fatalError` because a
    /// missing Application Support directory is an unrecoverable state.
    public static let shared: NavidromeStore = {
        do {
            return try NavidromeStore()
        } catch {
            fatalError("NavidromeStore: failed to open production database — \(error)")
        }
    }()

    // MARK: - Public writer

    /// The underlying GRDB writer.  Expose this so record types added in
    /// a6f.9 can perform reads and writes without the store growing a large
    /// query API surface prematurely.
    public let writer: any DatabaseWriter

    // MARK: - Initialisers

    /// Opens (or creates) the production SQLite database at
    /// `<Application Support>/Adagio Stream/navidrome.sqlite`, applies all
    /// pending migrations, and hardens file-protection attributes on the
    /// database file and its WAL sidecars.
    public convenience init() throws {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let dbDir = appSupport.appendingPathComponent(Constants.appName, isDirectory: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)

        let dbURL = dbDir.appendingPathComponent(Constants.StorageKeys.navidromeCache)

        var config = Configuration()
        config.prepareDatabase { db in
            // WAL is the default for DatabasePool; set it explicitly so it is
            // visible in the config and survives a hypothetical pool swap.
            try db.execute(sql: "PRAGMA journal_mode=WAL")
        }

        let pool = try DatabasePool(path: dbURL.path, configuration: config)

        // Apply file-protection after the pool is open so the main file, WAL
        // journal, and shared-memory file all exist on disk.
        NavidromeStore.applyFileProtection(to: dbURL)

        try self.init(writer: pool)
    }

    /// Injectable initialiser — pass any `DatabaseWriter` (a `DatabaseQueue`
    /// for in-memory tests, a `DatabasePool` for production).
    public init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    // MARK: - File-protection helpers

    /// Sets `.completeFileProtectionUntilFirstUserAuthentication` on the main
    /// SQLite file and its `.sqlite-wal` / `.sqlite-shm` sidecars.  GRDB only
    /// protects the main file by default; the sidecars must be set explicitly.
    ///
    /// GRDB names sidecars `<dbname>-wal` and `<dbname>-shm` (dash, not dot),
    /// so we derive them from the base path string rather than using URL path
    /// extension manipulation.
    private static func applyFileProtection(to dbURL: URL) {
        let basePath = dbURL.path
        let allPaths = [basePath, "\(basePath)-wal", "\(basePath)-shm"]

        let attrs: [FileAttributeKey: Any] = [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
        ]

        for path in allPaths where FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.setAttributes(attrs, ofItemAtPath: path)
        }
    }

    // MARK: - Migrator

    /// Forward-only migrator shared by all instances.  Registered migrations
    /// are additive — never modify an existing migration body.
    static let migrator: DatabaseMigrator = {
        var m = DatabaseMigrator()

        // ── v1: library cache ────────────────────────────────────────────────
        m.registerMigration("createLibraryCache") { db in
            // artists
            try db.execute(sql: """
                CREATE TABLE artists (
                    id          TEXT PRIMARY KEY NOT NULL,
                    name        TEXT NOT NULL,
                    sortName    TEXT,
                    albumCount  INTEGER NOT NULL DEFAULT 0,
                    coverArt    TEXT,
                    updatedAt   INTEGER NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE INDEX idx_artists_name
                    ON artists (name COLLATE NOCASE)
                """)
            try db.execute(sql: """
                CREATE INDEX idx_artists_sortName
                    ON artists (sortName COLLATE NOCASE)
                """)

            // albums
            try db.execute(sql: """
                CREATE TABLE albums (
                    id          TEXT PRIMARY KEY NOT NULL,
                    artistId    TEXT NOT NULL REFERENCES artists(id) ON DELETE CASCADE,
                    title       TEXT NOT NULL,
                    sortTitle   TEXT,
                    year        INTEGER,
                    genre       TEXT,
                    trackCount  INTEGER NOT NULL DEFAULT 0,
                    coverArt    TEXT,
                    updatedAt   INTEGER NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE INDEX idx_albums_artistId ON albums (artistId)
                """)
            try db.execute(sql: """
                CREATE INDEX idx_albums_genre    ON albums (genre)
                """)
            try db.execute(sql: """
                CREATE INDEX idx_albums_year     ON albums (year)
                """)
            try db.execute(sql: """
                CREATE INDEX idx_albums_title
                    ON albums (title COLLATE NOCASE)
                """)

            // tracks
            try db.execute(sql: """
                CREATE TABLE tracks (
                    id          TEXT PRIMARY KEY NOT NULL,
                    albumId     TEXT NOT NULL REFERENCES albums(id)  ON DELETE CASCADE,
                    artistId    TEXT NOT NULL REFERENCES artists(id) ON DELETE CASCADE,
                    title       TEXT NOT NULL,
                    trackNumber INTEGER,
                    discNumber  INTEGER NOT NULL DEFAULT 1,
                    duration    INTEGER,
                    genre       TEXT,
                    bitRate     INTEGER,
                    suffix      TEXT,
                    contentType TEXT,
                    coverArt    TEXT,
                    path        TEXT,
                    updatedAt   INTEGER NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE INDEX idx_tracks_albumId  ON tracks (albumId)
                """)
            try db.execute(sql: """
                CREATE INDEX idx_tracks_artistId ON tracks (artistId)
                """)
            try db.execute(sql: """
                CREATE INDEX idx_tracks_genre    ON tracks (genre)
                """)
            try db.execute(sql: """
                CREATE INDEX idx_tracks_title
                    ON tracks (title COLLATE NOCASE)
                """)
        }

        // ── v2: download index ───────────────────────────────────────────────
        // downloads has NO foreign key to tracks so it survives a library-cache
        // wipe (DROP/recreate of artists/albums/tracks).
        m.registerMigration("createDownloadIndex") { db in
            try db.execute(sql: """
                CREATE TABLE downloads (
                    id           TEXT PRIMARY KEY NOT NULL,
                    status       TEXT NOT NULL CHECK(
                                     status IN (
                                         'queued',
                                         'downloading',
                                         'paused',
                                         'completed',
                                         'failed'
                                     )
                                 ),
                    localPath    TEXT,
                    resumeOffset INTEGER NOT NULL DEFAULT 0,
                    error        TEXT,
                    createdAt    INTEGER NOT NULL,
                    updatedAt    INTEGER NOT NULL
                )
                """)
            // Partial index: active/pending downloads (scheduler hot-path).
            try db.execute(sql: """
                CREATE INDEX idx_downloads_active
                    ON downloads (status)
                    WHERE status IN ('queued', 'downloading')
                """)
            // Partial index: rows with a local file (cleanup / resume hot-path).
            try db.execute(sql: """
                CREATE INDEX idx_downloads_localPath
                    ON downloads (localPath)
                    WHERE localPath IS NOT NULL
                """)
        }

        return m
    }()
}
