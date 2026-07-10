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

    /// Chapter length in seconds (`end - start`), clamped to ≥ 0 so a bad/missing
    /// `end` in the payload can't produce a negative duration. bug 4xw.4.
    public var duration: Double { max(0, end - start) }
}

// MARK: - DTO Layer

/// A library from `GET /api/libraries`. Filter to `mediaType == "book"` in code.
public struct ABSLibraryDTO: Decodable, Equatable {
    public let id: String
    public let name: String
    public let mediaType: String

    public var isBook: Bool { mediaType == "book" }
    public var isPodcast: Bool { mediaType == "podcast" }
}

/// `GET /api/libraries` envelope.
public struct ABSLibrariesResponse: Decodable {
    public let libraries: [ABSLibraryDTO]
}

/// `GET /api/me/items-in-progress` envelope (Continue Listening).
public struct ABSItemsInProgressResponse: Decodable {
    public let libraryItems: [ABSLibraryItemDTO]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        libraryItems = (try? c.decode([ABSLibraryItemDTO].self, forKey: .libraryItems)) ?? []
    }

    enum CodingKeys: String, CodingKey { case libraryItems }
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
            author: meta?.displayAuthor,
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

    /// The expanded item's audio files (index + ino), empty on minified lists.
    public func audioFiles() -> [ABSAudioFileDTO] { media?.audioFiles ?? [] }

    /// The show's title, for a podcast library item. Same field as a book's
    /// title (`media.metadata.title`) — ABS uses one metadata shape for both.
    public var showTitle: String? { media?.metadata?.title }

    /// The show's episodes (expanded shape only), empty for books or minified lists.
    public func episodes() -> [ABSEpisodeDTO] { media?.episodes ?? [] }

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
///
/// Books and podcast shows share this type: books carry `chapters`/`audioFiles`
/// directly; podcast shows carry `episodes[]` instead (populated on the
/// expanded/detail shape — same convention as `audioFiles`). A show has no
/// single `duration`/`chapters` of its own, only per-episode.
public struct ABSMediaDTO: Decodable {
    public let duration: Double?
    public let metadata: ABSMetadataDTO?
    public let chapters: [ABSChapterDTO]?
    /// Present on the expanded item-detail shape; carries each file's `ino`
    /// (needed for the per-file download endpoint). Absent on minified lists.
    public let audioFiles: [ABSAudioFileDTO]?
    /// Podcast show episodes (expanded shape only). `nil`/empty for books.
    public let episodes: [ABSEpisodeDTO]?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        duration = try? c.decodeIfPresent(Double.self, forKey: .duration)
        metadata = try? c.decodeIfPresent(ABSMetadataDTO.self, forKey: .metadata)
        chapters = try? c.decodeIfPresent([ABSChapterDTO].self, forKey: .chapters)
        audioFiles = try? c.decodeIfPresent([ABSAudioFileDTO].self, forKey: .audioFiles)
        episodes = try? c.decodeIfPresent([ABSEpisodeDTO].self, forKey: .episodes)
    }

    enum CodingKeys: String, CodingKey { case duration, metadata, chapters, audioFiles, episodes }
}

/// One `media.episodes[]` entry on a podcast show's library item.
///
/// ponytail: field names coded to the documented ABS podcast API shape
/// (no live podcast library to validate against — see yha.1's adapter and the
/// `// ponytail:` note on `ABSEpisodeProgressKey`). `audioFile` mirrors the
/// book `ABSAudioFileDTO` (single file per episode, vs. an array for books).
public struct ABSEpisodeDTO: Decodable {
    public let id: String
    public let title: String?
    public let duration: Double?
    public let pubDate: String?
    public let audioFile: ABSAudioFileDTO?
    public let userMediaProgress: ABSMediaProgressDTO?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        duration = try? c.decodeIfPresent(Double.self, forKey: .duration)
        pubDate = try? c.decodeIfPresent(String.self, forKey: .pubDate)
        audioFile = try? c.decodeIfPresent(ABSAudioFileDTO.self, forKey: .audioFile)
        userMediaProgress = try? c.decodeIfPresent(ABSMediaProgressDTO.self, forKey: .userMediaProgress)
    }

    enum CodingKeys: String, CodingKey { case id, title, duration, pubDate, audioFile, userMediaProgress }
}

/// A `media.audioFiles[]` entry from the expanded item detail. `ino` is the
/// server file inode used by `GET /api/items/{id}/file/{ino}/download`; `index`
/// matches the playback session's `audioTracks[].index` so the two can be joined
/// to pair each track's global `startOffset` with its downloadable `ino`.
public struct ABSAudioFileDTO: Decodable {
    public let index: Int
    public let ino: String
    public let duration: Double?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = (try? c.decode(Int.self, forKey: .index)) ?? 0
        // `ino` is a string on ABS; some server versions emit it as a number.
        if let s = try? c.decode(String.self, forKey: .ino) {
            ino = s
        } else if let n = try? c.decode(Int64.self, forKey: .ino) {
            ino = String(n)
        } else {
            ino = ""
        }
        duration = try? c.decodeIfPresent(Double.self, forKey: .duration)
    }

    enum CodingKeys: String, CodingKey { case index, ino, duration }
}

/// `media.metadata` — title and author display fields.
///
/// Shared by books and podcast shows: books expose a flattened `authorName`
/// string; podcast shows expose `author` instead (same shape, different key —
/// ABS convention). `displayAuthor` picks whichever is present so callers don't
/// need to branch on media type.
public struct ABSMetadataDTO: Decodable {
    public let title: String?
    /// ABS exposes a flattened `authorName` string on book metadata.
    public let authorName: String?
    /// Podcast show metadata's author field (ABS naming differs from books').
    public let author: String?

    public var displayAuthor: String? { authorName ?? author }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        authorName = try? c.decodeIfPresent(String.self, forKey: .authorName)
        author = try? c.decodeIfPresent(String.self, forKey: .author)
    }

    enum CodingKeys: String, CodingKey { case title, authorName, author }
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

// MARK: - Offline progress update (E3 / mkj.2; episodeId added E1 / yha.4)

/// One item's progress, queued while offline and flushed via
/// `PATCH /api/me/progress/batch/update` on reconnect. Fields mirror the ABS
/// per-item progress payload. `Codable` so the pending queue persists to disk
/// across app launches.
///
/// `episodeId` is `nil` for books (unchanged from before podcasts existed) and
/// set for a podcast episode — see `ABSEpisodeProgressKey`, the seam that
/// decides whether a given item carries one.
public struct ABSProgressUpdate: Codable, Equatable {
    public let libraryItemId: String
    /// Podcast episode id, `nil` for books. ponytail: keyed per the documented
    /// (unvalidated) ABS podcast progress shape — see `ABSEpisodeProgressKey`.
    public let episodeId: String?
    public let currentTime: Double
    public let duration: Double
    public let progress: Double
    public let isFinished: Bool
    /// Client wall-clock (Unix millis) — the server uses it for last-writer-wins.
    public let lastUpdate: Int64

    public init(libraryItemId: String, episodeId: String? = nil, currentTime: Double, duration: Double, isFinished: Bool = false, lastUpdate: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        self.libraryItemId = libraryItemId
        self.episodeId = episodeId
        self.currentTime = currentTime
        self.duration = duration
        self.progress = duration > 0 ? min(1.0, max(0.0, currentTime / duration)) : 0
        self.isFinished = isFinished
        self.lastUpdate = lastUpdate
    }
}

// MARK: - Episode progress keying adapter (E1 / yha.1 — unvalidated, see below)

/// The one seam that decides how a podcast episode's progress is keyed and
/// addressed, isolated from every call site so an on-device correction against
/// a real ABS server is a one-line change here — not a scatter of `if let
/// episodeId` branches through the API/sync-queue/player.
///
/// ponytail: UNVALIDATED ASSUMPTION. There is no reachable podcast library to
/// test against, so this is coded strictly to the documented ABS API shape:
/// progress keyed by `(libraryItemId, episodeId)` and a dedicated per-episode
/// play endpoint. If a real server differs (e.g. a flat episode-only id, or no
/// episode-scoped play endpoint), only `ABSEpisodeProgressKey` and its two
/// methods below need to change. Follow-up: file a bead to validate podcast
/// episode progress on device once a podcast library is reachable.
public struct ABSEpisodeProgressKey: Equatable {
    public let libraryItemId: String
    /// `nil` for a book/show-level item; set for a podcast episode.
    public let episodeId: String?

    public init(libraryItemId: String, episodeId: String? = nil) {
        self.libraryItemId = libraryItemId
        self.episodeId = episodeId
    }

    /// `POST` path to open a playback session: per-episode for podcasts,
    /// per-item for books.
    public var playPath: String {
        if let episodeId {
            return "/api/items/\(libraryItemId)/play/\(episodeId)"
        }
        return "/api/items/\(libraryItemId)/play"
    }

    /// `PATCH` path for a single (non-batch) progress update.
    public var progressPath: String {
        if let episodeId {
            return "/api/me/progress/\(libraryItemId)/\(episodeId)"
        }
        return "/api/me/progress/\(libraryItemId)"
    }

    /// Builds the queued/batch progress update for this key.
    public func progressUpdate(currentTime: Double, duration: Double, isFinished: Bool = false, lastUpdate: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> ABSProgressUpdate {
        ABSProgressUpdate(
            libraryItemId: libraryItemId,
            episodeId: episodeId,
            currentTime: currentTime,
            duration: duration,
            isFinished: isFinished,
            lastUpdate: lastUpdate
        )
    }
}

// MARK: - Playback Session (E2 / yu8.2)

/// `POST /api/items/{id}/play` response — the playback session.
///
/// `currentTime` is the book-global RESUME position (seconds), seeded from the
/// user's server progress. `audioTracks[]` are the direct-play files, each with
/// a `startOffset` locating it on the book's single global timeline.
public struct ABSPlaybackSessionDTO: Decodable {
    public let id: String
    /// 0 = direct play, 1 = transcode. We request a wide mime list to force 0.
    public let playMethod: Int?
    /// Book-global resume position in seconds.
    public let currentTime: Double?
    public let duration: Double?
    public let chapters: [ABSChapterDTO]?
    public let audioTracks: [ABSAudioTrackDTO]?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        playMethod = try? c.decodeIfPresent(Int.self, forKey: .playMethod)
        currentTime = try? c.decodeIfPresent(Double.self, forKey: .currentTime)
        duration = try? c.decodeIfPresent(Double.self, forKey: .duration)
        chapters = try? c.decodeIfPresent([ABSChapterDTO].self, forKey: .chapters)
        audioTracks = try? c.decodeIfPresent([ABSAudioTrackDTO].self, forKey: .audioTracks)
    }

    enum CodingKeys: String, CodingKey {
        case id, playMethod, currentTime, duration, chapters, audioTracks
    }
}

/// One direct-play file within a playback session. `startOffset` is where this
/// file begins on the book's global timeline; `contentUrl` is server-relative.
public struct ABSAudioTrackDTO: Decodable {
    public let index: Int
    public let startOffset: Double
    public let duration: Double
    public let title: String?
    public let contentUrl: String

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = (try? c.decode(Int.self, forKey: .index)) ?? 0
        startOffset = (try? c.decode(Double.self, forKey: .startOffset)) ?? 0
        duration = (try? c.decode(Double.self, forKey: .duration)) ?? 0
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        contentUrl = (try? c.decode(String.self, forKey: .contentUrl)) ?? ""
    }

    enum CodingKeys: String, CodingKey {
        case index, startOffset, duration, title, contentUrl
    }
}

// MARK: - Audiobook Timeline (E2 / yu8.2 — pure, unit-tested core)

/// The book as ONE continuous timeline across its files.
///
/// This is the value-type core of audiobook playback: it owns every conversion
/// between book-global time and (file, offset-within-file), so the player just
/// asks it "which file plays global time T, and at what per-file position" and
/// "what plays after this file ends". It has no VLC/UIKit dependency and is
/// covered by unit tests.
public struct AudiobookTimeline: Equatable {
    /// Files in play order, each carrying its global `startOffset` and duration.
    public struct File: Equatable {
        public let index: Int
        public let startOffset: Double
        public let duration: Double
        public let contentPath: String

        public init(index: Int, startOffset: Double, duration: Double, contentPath: String) {
            self.index = index
            self.startOffset = startOffset
            self.duration = duration
            self.contentPath = contentPath
        }

        /// Global time (exclusive) at which this file ends.
        public var endOffset: Double { startOffset + duration }
    }

    public let files: [File]
    public let chapters: [AudiobookChapter]
    public let totalDuration: Double

    public init(files: [File], chapters: [AudiobookChapter] = []) {
        // Keep files sorted by startOffset so lookups are well-defined even if
        // the server ever returns them out of order.
        self.files = files.sorted { $0.startOffset < $1.startOffset }
        self.chapters = chapters
        self.totalDuration = self.files.map(\.endOffset).max() ?? 0
    }

    /// Builds a timeline from a play-session response.
    public init(session: ABSPlaybackSessionDTO, bookId: String) {
        let files = (session.audioTracks ?? []).map {
            File(index: $0.index, startOffset: $0.startOffset, duration: $0.duration, contentPath: $0.contentUrl)
        }
        let chapters = (session.chapters ?? []).map {
            AudiobookChapter(id: "\(bookId)#\($0.id)", bookId: bookId, title: $0.title, start: $0.start, end: $0.end)
        }
        self.init(files: files, chapters: chapters)
    }

    /// The file that plays global time `t`, plus the per-file offset to seek to.
    ///
    /// `t` is clamped to `[0, totalDuration]`. Returns `nil` only when there are
    /// no files. For `t` at or past the end, returns the last file at its end.
    public func locate(global t: Double) -> (file: File, fileOffset: Double)? {
        guard !files.isEmpty else { return nil }
        let clamped = max(0, min(t, totalDuration))
        // First file whose range contains `clamped` (startOffset <= t < endOffset).
        if let file = files.first(where: { clamped >= $0.startOffset && clamped < $0.endOffset }) {
            return (file, clamped - file.startOffset)
        }
        // Exactly at (or past) the end: sit at the end of the last file.
        let last = files[files.count - 1]
        return (last, max(0, clamped - last.startOffset))
    }

    /// The file that plays after `file` ends, or `nil` at the end of the book.
    public func fileAfter(_ file: File) -> File? {
        guard let pos = files.firstIndex(where: { $0.index == file.index }),
              pos + 1 < files.count else { return nil }
        return files[pos + 1]
    }

    /// Maps a per-file position back to book-global time.
    public func globalTime(file: File, fileOffset: Double) -> Double {
        file.startOffset + max(0, fileOffset)
    }

    /// The chapter covering global time `t` (start <= t < end), if any.
    public func chapter(at t: Double) -> AudiobookChapter? {
        chapters.first { t >= $0.start && t < $0.end } ?? chapters.last { t >= $0.start }
    }

    /// Global start time of the next chapter after `t`, or `nil` if none.
    public func nextChapterStart(after t: Double) -> Double? {
        chapters.first { $0.start > t + 0.5 }?.start
    }

    /// Global start time to jump to for "previous chapter" from `t`.
    ///
    /// Mirrors iOS Music/Podcasts behaviour: if more than ~3 s into the current
    /// chapter, previous restarts the current chapter; otherwise it jumps to the
    /// start of the preceding chapter. Returns `nil` when there are no chapters.
    public func previousChapterStart(from t: Double) -> Double? {
        guard let current = chapter(at: t) else {
            return chapters.last { $0.start < t }?.start
        }
        if t - current.start > 3.0 { return current.start }
        return chapters.last { $0.start < current.start }?.start ?? current.start
    }
}
