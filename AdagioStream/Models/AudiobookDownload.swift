// MARK: - Audiobookshelf Offline Download Model (E3 / mkj.1)
//
// A downloaded book is a manifest of its audio files plus the global-timeline
// chapters, persisted so offline playback rebuilds the SAME `AudiobookTimeline`
// it would get from a live `/play` session. Each file carries its `startOffset`
// on the book-global timeline (captured from the streaming session at download
// time) and, once fetched, its on-disk `localPath`.
//
// Stored in the `audiobook_downloads` table (v5 migration) as two JSON blobs
// (files + chapters) so the record stays flat and the manifest travels with the
// row. No UIKit — shared across iOS/tvOS.

import Foundation
import GRDB

// MARK: - Per-file manifest entry

/// One audio file of a downloaded book. `startOffset`/`duration` are seconds on
/// the book-global timeline (verbatim from the streaming session's
/// `audioTracks[]`), so `AudiobookTimeline` reconstruction is exact. `ino` is
/// the server file inode used by `GET /api/items/{id}/file/{ino}/download`.
public struct AudiobookDownloadFile: Codable, Equatable {
    public var index: Int
    public var ino: String
    public var startOffset: Double
    public var duration: Double
    /// Absolute on-disk path once the file has finished downloading; `nil` while pending.
    public var localPath: String?

    public init(index: Int, ino: String, startOffset: Double, duration: Double, localPath: String? = nil) {
        self.index = index
        self.ino = ino
        self.startOffset = startOffset
        self.duration = duration
        self.localPath = localPath
    }

    /// True when the file has a local path AND that file exists on disk.
    public var isPresent: Bool {
        guard let localPath else { return false }
        return FileManager.default.fileExists(atPath: localPath)
    }
}

// MARK: - GRDB record

/// A row in `audiobook_downloads` — one per book. Manifest + chapters are stored
/// as JSON columns; the typed `files` / `chapters` accessors decode them.
public struct AudiobookDownloadRecord: FetchableRecord, PersistableRecord, Equatable {
    public static let databaseTableName = "audiobook_downloads"

    public var id: String            // ABS library-item id
    public var title: String
    public var author: String?
    public var coverPath: String?
    public var duration: Double?
    public var status: DownloadStatus
    public var files: [AudiobookDownloadFile]
    public var chapters: [AudiobookChapter]
    public var error: String?
    public var createdAt: Int
    public var updatedAt: Int
    /// Local resume cache (beads_mobilemusic-uxi), updated at the same points
    /// progress is synced during playback (pause/stop/periodic/seek — see
    /// `AudioPlayerService.syncAudiobookProgress`), regardless of whether that
    /// playback was online or offline. Closes the gap where an item last
    /// played ONLINE had no local progress to resume from on first offline
    /// play — the offline progress queue (`ABSProgressSyncQueue`) only has an
    /// entry when the LAST play was offline. `nil` for a record never played
    /// since this field was added, or never played at all — existing rows
    /// from before this migration decode as `nil` (added via nullable
    /// `ALTER TABLE ADD COLUMN`, no default; see NavidromeStore v6 migration).
    public var currentTime: TimeInterval?

    public init(
        id: String,
        title: String,
        author: String? = nil,
        coverPath: String? = nil,
        duration: Double? = nil,
        status: DownloadStatus,
        files: [AudiobookDownloadFile],
        chapters: [AudiobookChapter],
        error: String? = nil,
        createdAt: Int,
        updatedAt: Int,
        currentTime: TimeInterval? = nil
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.coverPath = coverPath
        self.duration = duration
        self.status = status
        self.files = files
        self.chapters = chapters
        self.error = error
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.currentTime = currentTime
    }

    /// True when every file in the manifest is present on disk.
    public var allFilesPresent: Bool {
        !files.isEmpty && files.allSatisfy { $0.isPresent }
    }

    // MARK: GRDB row bridging (manifest columns are JSON text)

    enum Columns: String, ColumnExpression {
        case id, title, author, coverPath, duration, status, filesJSON, chaptersJSON, error, createdAt, updatedAt, currentTime
    }

    public init(row: Row) throws {
        id = row[Columns.id]
        title = row[Columns.title]
        author = row[Columns.author]
        coverPath = row[Columns.coverPath]
        duration = row[Columns.duration]
        status = DownloadStatus(rawValue: row[Columns.status]) ?? .failed
        let filesText: String = row[Columns.filesJSON]
        let chaptersText: String = row[Columns.chaptersJSON]
        files = (try? JSONDecoder().decode([AudiobookDownloadFile].self, from: Data(filesText.utf8))) ?? []
        chapters = (try? JSONDecoder().decode([AudiobookChapter].self, from: Data(chaptersText.utf8))) ?? []
        error = row[Columns.error]
        createdAt = row[Columns.createdAt]
        updatedAt = row[Columns.updatedAt]
        // Nullable, no default (v6 migration) — absent/NULL on rows persisted
        // before this field existed decodes cleanly as nil.
        currentTime = row[Columns.currentTime]
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container[Columns.id] = id
        container[Columns.title] = title
        container[Columns.author] = author
        container[Columns.coverPath] = coverPath
        container[Columns.duration] = duration
        container[Columns.status] = status.rawValue
        container[Columns.filesJSON] = String(decoding: (try? JSONEncoder().encode(files)) ?? Data("[]".utf8), as: UTF8.self)
        container[Columns.chaptersJSON] = String(decoding: (try? JSONEncoder().encode(chapters)) ?? Data("[]".utf8), as: UTF8.self)
        container[Columns.error] = error
        container[Columns.createdAt] = createdAt
        container[Columns.updatedAt] = updatedAt
        container[Columns.currentTime] = currentTime
    }
}

// MARK: - Podcast episode downloads (E4 / 6b5.1)
//
// An episode is a downloaded book with exactly ONE file — index 0, startOffset
// 0, no chapters — riding the same manifest/timeline/DownloadManager machinery
// books use. `id` is namespaced "ep#<showId>#<episodeId>" (mirrors
// `DownloadManager.bookTaskDescription`'s "abs#<bookId>#<ino>" convention) so
// an episode's row can never collide with a book's plain-libraryItemId `id` in
// the same `audiobook_downloads` table, and so a completed row can be parsed
// back into its show/episode ids for display + progress-keyed deletion.
extension AudiobookDownloadRecord {
    private static let episodeIDPrefix = "ep#"

    /// Builds the composite `AudiobookDownloadRecord.id` for one episode.
    public static func episodeRecordID(showID: String, episodeID: String) -> String {
        "\(episodeIDPrefix)\(showID)#\(episodeID)"
    }

    /// Parses a record id back into `(showID, episodeID)`, or `nil` when the id
    /// is a plain book libraryItemId (no prefix).
    public static func parseEpisodeRecordID(_ id: String) -> (showID: String, episodeID: String)? {
        guard id.hasPrefix(episodeIDPrefix) else { return nil }
        let parts = id.dropFirst(episodeIDPrefix.count).split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    /// True when this record is a downloaded podcast episode (vs. a book).
    public var isEpisodeDownload: Bool {
        Self.parseEpisodeRecordID(id) != nil
    }

    /// The SERVER library-item id for a given download-record id — the id the
    /// ABS file-download endpoint (`/api/items/<id>/file/<ino>/download`) expects.
    /// For an episode record `ep#<showID>#<episodeID>` the server item is the
    /// SHOW (`showID`); for a book the record id IS the server item id. Pure.
    public static func serverItemID(forRecordID recordID: String) -> String {
        parseEpisodeRecordID(recordID)?.showID ?? recordID
    }

    /// Reconstructs the minimal `ABSEpisodeDTO` + single-episode
    /// `PodcastPlaybackContext` this record represents, for playback with no
    /// server round-trip. `nil` when `id` isn't an episode record (see
    /// `parseEpisodeRecordID`). Shared by `MusicLibraryView.playOfflineEpisode`
    /// (uxc.1) and CarPlay's resume-target offline fallback
    /// (beads_mobilemusic-cpr kickback round 2) — one reconstruction, not two.
    public func reconstructedEpisode() -> (episode: ABSEpisodeDTO, context: PodcastPlaybackContext)? {
        guard let (showID, episodeID) = Self.parseEpisodeRecordID(id) else { return nil }
        let episode = ABSEpisodeDTO(id: episodeID, title: title, duration: duration)
        let context = PodcastPlaybackContext(libraryItemId: showID, showTitle: author, episodes: [episode])
        return (episode, context)
    }

    /// Maps one podcast episode into a 1-file download manifest: index 0,
    /// startOffset 0, empty chapters — the whole episode is a single audio file
    /// with no internal chapter structure (E2 scope), so `timeline()` rebuilds
    /// it as a one-file book. `nil` when the episode has no downloadable audio
    /// file (e.g. a minified/undecoded episode shape).
    public static func forEpisode(
        showID: String,
        showTitle: String?,
        episodeID: String,
        episodeTitle: String?,
        coverPath: String?,
        audioFile: ABSAudioFileDTO?
    ) -> AudiobookDownloadRecord? {
        guard let audioFile, !audioFile.ino.isEmpty else { return nil }
        let now = Int(Date().timeIntervalSince1970)
        let file = AudiobookDownloadFile(
            index: 0,
            ino: audioFile.ino,
            startOffset: 0,
            duration: audioFile.duration ?? 0
        )
        return AudiobookDownloadRecord(
            id: episodeRecordID(showID: showID, episodeID: episodeID),
            title: episodeTitle ?? "Episode",
            author: showTitle,
            coverPath: coverPath,
            duration: audioFile.duration,
            status: .downloading,
            files: [file],
            chapters: [],
            createdAt: now,
            updatedAt: now
        )
    }
}

// MARK: - Timeline reconstruction (offline mirror of the streaming session)

extension AudiobookDownloadRecord {
    /// Rebuilds the book's `AudiobookTimeline` from the persisted manifest using
    /// the on-disk file paths as `contentPath`. Mirrors
    /// `AudiobookTimeline(session:bookId:)` so offline playback chains files and
    /// maps global↔file exactly as streaming does. Files without a local path
    /// yet are skipped.
    public func timeline() -> AudiobookTimeline {
        let tlFiles = files.compactMap { f -> AudiobookTimeline.File? in
            guard let path = f.localPath else { return nil }
            return AudiobookTimeline.File(
                index: f.index,
                startOffset: f.startOffset,
                duration: f.duration,
                contentPath: path
            )
        }
        return AudiobookTimeline(files: tlFiles, chapters: chapters)
    }
}
