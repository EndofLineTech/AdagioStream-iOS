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

        // ── v3: denormalised artist name on tracks ───────────────────────────
        // The Subsonic song payload carries a human-readable `artist` string that
        // we previously discarded (only artistId was kept).  Storing it lets the
        // now-playing UI, queue list, and lock screen show the real artist for any
        // playback source — not just album playback where the name was threaded
        // in from the artist screen (bug c2o).  Nullable: pre-existing cached rows
        // backfill on the next library fetch.
        m.registerMigration("addTrackArtistName") { db in
            try db.execute(sql: "ALTER TABLE tracks ADD COLUMN artist TEXT")
        }

        return m
    }()
}

// MARK: - Download record type

/// The valid status values for a download row, matching the CHECK constraint
/// in the v2 `downloads` migration.
///
/// The raw values are the exact strings stored in the database — do not
/// change them without a corresponding schema migration.
public enum DownloadStatus: String, Codable, CaseIterable {
    /// Queued and waiting for an available download slot.
    case queued
    /// Actively being transferred from the server.
    case downloading
    /// Transfer suspended (e.g. user pause or connectivity loss).
    case paused
    /// Transfer finished; `localPath` points to the on-disk file.
    case completed
    /// Transfer ended with an error; `error` carries the failure message.
    case failed
}

/// A row in the `downloads` table (v2 schema).
///
/// The `id` is the Navidrome track ID — there is intentionally NO foreign key
/// to the `tracks` table so the download index survives a library-cache wipe.
///
/// Conforms to `FetchableRecord` and `PersistableRecord` using the default
/// Codable synthesis.  All column names use camelCase matching the schema
/// (GRDB maps Swift property names 1-to-1 to SQLite column names).
public struct DownloadRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    public static let databaseTableName = "downloads"

    /// Navidrome track ID (PRIMARY KEY).
    public var id: String
    /// Current lifecycle status.
    public var status: DownloadStatus
    /// Absolute path to the on-disk file; non-nil when `status == .completed`.
    public var localPath: String?
    /// Bytes already received — used to store a resume position.
    public var resumeOffset: Int
    /// Human-readable error message; non-nil when `status == .failed`.
    public var error: String?
    /// Unix timestamp (seconds) when the row was first inserted.
    public var createdAt: Int
    /// Unix timestamp (seconds) of the last status update.
    public var updatedAt: Int

    public init(
        id: String,
        status: DownloadStatus,
        localPath: String? = nil,
        resumeOffset: Int = 0,
        error: String? = nil,
        createdAt: Int,
        updatedAt: Int
    ) {
        self.id = id
        self.status = status
        self.localPath = localPath
        self.resumeOffset = resumeOffset
        self.error = error
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Typed CRUD

extension NavidromeStore {

    // MARK: Upsert (insert or replace)

    /// Upserts an array of `Artist` records.  Each record is saved using
    /// GRDB's `save(_:)` which performs INSERT OR REPLACE based on primary key.
    public func upsert(artists: [Artist]) throws {
        try writer.write { db in
            for artist in artists { try artist.save(db) }
        }
    }

    /// Upserts an array of `Album` records.
    public func upsert(albums: [Album]) throws {
        try writer.write { db in
            for album in albums { try album.save(db) }
        }
    }

    /// Upserts an array of `Track` records.
    public func upsert(tracks: [Track]) throws {
        try writer.write { db in
            for track in tracks { try track.save(db) }
        }
    }

    // MARK: Fetch helpers

    /// Returns all albums belonging to the given artist, ordered by year then
    /// title.
    public func albums(forArtist artistId: String) throws -> [Album] {
        try writer.read { db in
            try Album
                .filter(Column("artistId") == artistId)
                .order(Column("year"), Column("title"))
                .fetchAll(db)
        }
    }

    /// Returns all tracks belonging to the given album, ordered by disc number
    /// then track number.
    public func tracks(forAlbum albumId: String) throws -> [Track] {
        try writer.read { db in
            try Track
                .filter(Column("albumId") == albumId)
                .order(Column("discNumber"), Column("trackNumber"))
                .fetchAll(db)
        }
    }

    // MARK: - Download CRUD (v2 schema)

    /// Upserts a `DownloadRecord` — inserts a new row or replaces an existing
    /// row with the same `id`.
    public func upsert(download: DownloadRecord) throws {
        try writer.write { db in
            try download.save(db)
        }
    }

    /// Returns the `DownloadRecord` for the given track ID, or `nil` if not found.
    public func download(forTrackID trackID: String) throws -> DownloadRecord? {
        try writer.read { db in
            try DownloadRecord.fetchOne(db, key: trackID)
        }
    }

    /// Returns all download rows, ordered by creation time ascending.
    public func allDownloads() throws -> [DownloadRecord] {
        try writer.read { db in
            try DownloadRecord
                .order(Column("createdAt"))
                .fetchAll(db)
        }
    }

    /// Returns all download rows matching the given status, ordered by creation
    /// time ascending.
    public func downloads(withStatus status: DownloadStatus) throws -> [DownloadRecord] {
        try writer.read { db in
            try DownloadRecord
                .filter(Column("status") == status.rawValue)
                .order(Column("createdAt"))
                .fetchAll(db)
        }
    }

    /// Updates the status (and optionally localPath, error, resumeOffset) of an
    /// existing download row.  The `updatedAt` timestamp is always set to the
    /// current Unix epoch seconds.
    ///
    /// If no row exists for `trackID` this is a no-op (returns without throwing).
    public func updateDownload(
        trackID: String,
        status: DownloadStatus,
        localPath: String? = nil,
        error: String? = nil,
        resumeOffset: Int? = nil
    ) throws {
        let now = Int(Date().timeIntervalSince1970)
        try writer.write { db in
            guard var record = try DownloadRecord.fetchOne(db, key: trackID) else {
                return
            }
            record.status = status
            if let localPath { record.localPath = localPath }
            if let error { record.error = error }
            if let resumeOffset { record.resumeOffset = resumeOffset }
            record.updatedAt = now
            try record.save(db)
        }
    }

    /// Deletes the download row for the given track ID.  Idempotent — missing
    /// rows are silently ignored.
    public func deleteDownload(forTrackID trackID: String) throws {
        try writer.write { db in
            _ = try DownloadRecord.deleteOne(db, key: trackID)
        }
    }

    /// Returns the total number of bytes stored across all completed downloads,
    /// computed from the file sizes on disk.  Rows without a `localPath` or
    /// whose file no longer exists contribute 0.
    public func totalDownloadedBytes() throws -> Int64 {
        let records = try downloads(withStatus: .completed)
        return records.reduce(Int64(0)) { total, record in
            guard let path = record.localPath else { return total }
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let size = attrs?[.size] as? Int64 ?? 0
            return total + size
        }
    }

    /// Deletes every download row and the associated on-disk files.
    ///
    /// Files that fail to delete are silently ignored (the row is still removed).
    public func deleteAllDownloads() throws {
        let records = try allDownloads()
        for record in records {
            if let path = record.localPath {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        try writer.write { db in
            _ = try DownloadRecord.deleteAll(db)
        }
    }
}
