// MARK: - Audiobookshelf Domain Models
//
// Same DTO→record approach as NavidromeModels.swift: the GRDB record types
// (Audiobook, AudiobookChapter) use property names that match the schema
// columns exactly, so the default Codable-based FetchableRecord /
// PersistableRecord synthesis works without custom CodingKeys on the record
// side. Lightweight DTO structs own the Audiobookshelf-specific JSON decoding
// and expose `toRecord()` / `chapters()` transforms.
//
// Chapter start/end are GLOBAL-timeline seconds (they span the book's file
// boundaries), taken verbatim from the ABS `media.chapters[]` payload.

import Foundation
import GRDB

// MARK: - GRDB Record Types

/// A book persisted to the `audiobooks` table.
///
/// `id` is the ABS library-item id (also stored as `libraryItemId` so the
/// naming intent is explicit and future joins read clearly). Progress fields
/// mirror the server's per-user `mediaProgress` for this item.
public struct Audiobook: Codable, FetchableRecord, PersistableRecord, Equatable {
    public static let databaseTableName = "audiobooks"

    public var id: String
    public var libraryItemId: String
    public var libraryId: String
    public var title: String
    public var author: String?
    /// Total duration in seconds.
    public var duration: Double?
    /// Server-relative cover path (prepend the provider base URL to fetch).
    public var coverPath: String?
    /// Server-side listening position in seconds.
    public var currentTime: Double
    /// Fractional progress 0.0–1.0.
    public var progress: Double
    /// Whether the server marks this book finished.
    public var isFinished: Bool
    /// Server progress last-update timestamp (Unix epoch millis), 0 when unknown.
    public var lastUpdate: Int64
    /// Local sync timestamp (Unix epoch seconds).
    public var updatedAt: Int

    public init(
        id: String,
        libraryItemId: String,
        libraryId: String,
        title: String,
        author: String? = nil,
        duration: Double? = nil,
        coverPath: String? = nil,
        currentTime: Double = 0,
        progress: Double = 0,
        isFinished: Bool = false,
        lastUpdate: Int64 = 0,
        updatedAt: Int
    ) {
        self.id = id
        self.libraryItemId = libraryItemId
        self.libraryId = libraryId
        self.title = title
        self.author = author
        self.duration = duration
        self.coverPath = coverPath
        self.currentTime = currentTime
        self.progress = progress
        self.isFinished = isFinished
        self.lastUpdate = lastUpdate
        self.updatedAt = updatedAt
    }
}

/// A chapter persisted to the `chapters` table.
///
/// `start`/`end` are global-timeline seconds spanning file boundaries.
public struct AudiobookChapter: Codable, FetchableRecord, PersistableRecord, Equatable {
    public static let databaseTableName = "chapters"

    /// Composite key `"<bookId>#<index>"` — ABS chapters have an `id` that is a
    /// per-book sequential index, so we namespace it by book to stay globally
    /// unique across the table.
    public var id: String
    public var bookId: String
    public var title: String
    public var start: Double
    public var end: Double

    public init(id: String, bookId: String, title: String, start: Double, end: Double) {
        self.id = id
        self.bookId = bookId
        self.title = title
        self.start = start
        self.end = end
    }
}

// MARK: - DTO Layer

/// A library from `GET /api/libraries`. Filter to `mediaType == "book"` in code.
public struct ABSLibraryDTO: Decodable, Equatable {
    public let id: String
    public let name: String
    public let mediaType: String

    public var isBook: Bool { mediaType == "book" }
}

/// `GET /api/libraries` envelope.
public struct ABSLibrariesResponse: Decodable {
    public let libraries: [ABSLibraryDTO]
}

/// `GET /api/libraries/{id}/items` envelope. `results` holds the book items.
public struct ABSLibraryItemsResponse: Decodable {
    public let results: [ABSLibraryItemDTO]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        results = (try? c.decode([ABSLibraryItemDTO].self, forKey: .results)) ?? []
    }

    enum CodingKeys: String, CodingKey { case results }
}

/// A single ABS library item (`GET /api/items/{id}` or an entry in a list).
///
/// The book fields live under `media.metadata`; chapters under `media.chapters`;
/// this user's progress under `userMediaProgress` (present with
/// `?include=progress`). All optional so both the minified list shape and the
/// expanded detail shape decode from the same type.
public struct ABSLibraryItemDTO: Decodable {
    public let id: String
    public let libraryId: String?
    public let media: ABSMediaDTO?
    public let userMediaProgress: ABSMediaProgressDTO?

    enum CodingKeys: String, CodingKey {
        case id, libraryId, media, userMediaProgress
    }

    /// Transforms the item into an `Audiobook` record. `libraryIdFallback` is
    /// used when the item payload omits `libraryId` (e.g. the item-detail shape).
    public func toRecord(libraryIdFallback: String, updatedAt: Int) -> Audiobook {
        let meta = media?.metadata
        let progress = userMediaProgress
        return Audiobook(
            id: id,
            libraryItemId: id,
            libraryId: libraryId ?? libraryIdFallback,
            title: meta?.title ?? "Untitled",
            author: meta?.authorName,
            duration: media?.duration,
            coverPath: coverPath,
            currentTime: progress?.currentTime ?? 0,
            progress: progress?.progress ?? 0,
            isFinished: progress?.isFinished ?? false,
            lastUpdate: progress?.lastUpdate ?? 0,
            updatedAt: updatedAt
        )
    }

    /// Server-relative cover path for `GET /api/items/{id}/cover`.
    public var coverPath: String { "/api/items/\(id)/cover" }

    /// Transforms `media.chapters[]` into `[AudiobookChapter]` records. Start/end
    /// are already global-timeline seconds in the ABS payload — passed through.
    public func chapters() -> [AudiobookChapter] {
        (media?.chapters ?? []).map { ch in
            AudiobookChapter(
                id: "\(id)#\(ch.id)",
                bookId: id,
                title: ch.title,
                start: ch.start,
                end: ch.end
            )
        }
    }
}

/// The `media` object of a library item.
public struct ABSMediaDTO: Decodable {
    public let duration: Double?
    public let metadata: ABSMetadataDTO?
    public let chapters: [ABSChapterDTO]?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        duration = try? c.decodeIfPresent(Double.self, forKey: .duration)
        metadata = try? c.decodeIfPresent(ABSMetadataDTO.self, forKey: .metadata)
        chapters = try? c.decodeIfPresent([ABSChapterDTO].self, forKey: .chapters)
    }

    enum CodingKeys: String, CodingKey { case duration, metadata, chapters }
}

/// `media.metadata` — title and author display fields.
public struct ABSMetadataDTO: Decodable {
    public let title: String?
    /// ABS exposes a flattened `authorName` string on book metadata.
    public let authorName: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        authorName = try? c.decodeIfPresent(String.self, forKey: .authorName)
    }

    enum CodingKeys: String, CodingKey { case title, authorName }
}

/// A `media.chapters[]` entry. `start`/`end` are global-timeline seconds.
public struct ABSChapterDTO: Decodable {
    public let id: Int
    public let title: String
    public let start: Double
    public let end: Double

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int.self, forKey: .id)) ?? 0
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        start = (try? c.decode(Double.self, forKey: .start)) ?? 0
        end = (try? c.decode(Double.self, forKey: .end)) ?? 0
    }

    enum CodingKeys: String, CodingKey { case id, title, start, end }
}

/// Per-user media progress (from login payload or `?include=progress`).
public struct ABSMediaProgressDTO: Decodable {
    public let currentTime: Double?
    public let progress: Double?
    public let isFinished: Bool?
    public let lastUpdate: Int64?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        currentTime = try? c.decodeIfPresent(Double.self, forKey: .currentTime)
        progress = try? c.decodeIfPresent(Double.self, forKey: .progress)
        isFinished = try? c.decodeIfPresent(Bool.self, forKey: .isFinished)
        lastUpdate = try? c.decodeIfPresent(Int64.self, forKey: .lastUpdate)
    }

    enum CodingKeys: String, CodingKey { case currentTime, progress, isFinished, lastUpdate }
}
