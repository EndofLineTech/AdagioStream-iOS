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
        updatedAt: Int
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
    }

    /// True when every file in the manifest is present on disk.
    public var allFilesPresent: Bool {
        !files.isEmpty && files.allSatisfy { $0.isPresent }
    }

    // MARK: GRDB row bridging (manifest columns are JSON text)

    enum Columns: String, ColumnExpression {
        case id, title, author, coverPath, duration, status, filesJSON, chaptersJSON, error, createdAt, updatedAt
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
