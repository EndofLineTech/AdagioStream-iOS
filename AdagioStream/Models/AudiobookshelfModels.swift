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
    /// TOP-LEVEL field sent only by `GET /api/me/items-in-progress` for an
    /// in-progress podcast: the recently-played episode (with its own
    /// `userMediaProgress`). This endpoint sends a MINIFIED item — `numEpisodes`
    /// but no `media.episodes[]` — so `recentEpisode` (not `media.episodes`) is
    /// the authoritative signal that an in-progress item is a podcast episode.
    public let recentEpisode: ABSEpisodeDTO?

    enum CodingKeys: String, CodingKey {
        case id, libraryId, media, userMediaProgress, recentEpisode
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

    /// Memberwise init for reconstructing an episode offline from a downloaded
    /// manifest (`AudiobookDownloadRecord`, uxc.1) — no server round-trip
    /// available, so this bypasses the JSON-decoding path above.
    public init(
        id: String,
        title: String?,
        duration: Double?,
        pubDate: String? = nil,
        audioFile: ABSAudioFileDTO? = nil,
        userMediaProgress: ABSMediaProgressDTO? = nil
    ) {
        self.id = id
        self.title = title
        self.duration = duration
        self.pubDate = pubDate
        self.audioFile = audioFile
        self.userMediaProgress = userMediaProgress
    }

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

// MARK: - Podcast whole-show auto-play (E2 / 72i.2)

/// Which direction "next episode" advances through a show's episode list.
///
/// ABS returns `media.episodes[]` newest-first by server convention, so
/// `.newestFirst` (the default) walks the list in server order; `.oldestFirst`
/// walks it reversed. c2s.4 will add a user setting that drives this — the
/// hookup point is the `order:` parameter on `PodcastPlaybackContext.nextEpisode`
/// below, so wiring a setting in later is a one-line call-site change.
public enum PodcastEpisodeOrder: String, Codable, CaseIterable {
    case newestFirst
    case oldestFirst
}

/// What to auto-play when a podcast episode ends (beads_mobilemusic-5aj.2).
///
/// Replaces the old "walk `sortedEpisodes` one slot forward" behavior, which
/// under the default `.newestFirst` display order silently played the next
/// OLDER (already-heard) episode — the reported TestFlight bug. Default is
/// `.nextUnplayed`: it can only advance into the future, so finishing the
/// newest episode stops instead of replaying something older.
public enum PodcastEpisodeEndBehavior: String, Codable, CaseIterable {
    /// Stop at the end of the episode. No auto-advance.
    case stop
    /// Advance to the closest unplayed episode with a `pubDate` strictly
    /// newer than the current one. Stops when nothing newer/unplayed exists.
    case nextUnplayed
    /// Walk the list in the user's chosen display order (`PodcastEpisodeOrder`),
    /// skipping already-finished episodes. Stops when none remain.
    case continueInSortOrder

    public var label: String {
        switch self {
        case .stop: "Stop"
        case .nextUnplayed: "Play Next Unplayed Episode"
        case .continueInSortOrder: "Continue in Sort Order"
        }
    }
}

/// The show's episode list + a pointer to what's currently playing — enough
/// state to answer "what plays after this episode ends" without re-fetching.
/// Pure/value-type so auto-play selection is unit-testable without VLC or the
/// network.
public struct PodcastPlaybackContext: Equatable {
    public let libraryItemId: String
    public let showTitle: String?
    /// Episodes in the server's native (newest-first) order.
    public let episodes: [ABSEpisodeDTO]
    public let order: PodcastEpisodeOrder

    public init(libraryItemId: String, showTitle: String?, episodes: [ABSEpisodeDTO], order: PodcastEpisodeOrder = .newestFirst) {
        self.libraryItemId = libraryItemId
        self.showTitle = showTitle
        self.episodes = episodes
        self.order = order
    }

    public static func == (lhs: PodcastPlaybackContext, rhs: PodcastPlaybackContext) -> Bool {
        lhs.libraryItemId == rhs.libraryItemId
            && lhs.showTitle == rhs.showTitle
            && lhs.order == rhs.order
            && lhs.episodes.map(\.id) == rhs.episodes.map(\.id)
    }

    /// The episode that plays after `currentEpisodeId` ends, per `behavior`
    /// (beads_mobilemusic-5aj.2). `nil` means stop — either the policy says so
    /// (`.stop`), or there's nothing left that qualifies.
    ///
    /// Pure — does no I/O. `isFinished` is an injected predicate so the caller
    /// can hydrate per-episode progress on demand (episodes here carry no
    /// `userMediaProgress`, see `AudiobookshelfAPI.episodeProgress`) without
    /// this function knowing about the network. Callers walking forward should
    /// call this once per candidate as they hydrate it, not all at once.
    ///
    /// - `.nextUnplayed`: closest strictly-newer-by-`pubDate` unfinished
    ///   episode, regardless of display `order`. Undated episodes have no
    ///   comparable `pubDate` and are never selected.
    /// - `.continueInSortOrder`: first unfinished episode walking `order`
    ///   forward from `currentEpisodeId` in `sortedEpisodes`.
    public static func nextEpisode(
        in episodes: [ABSEpisodeDTO],
        after currentEpisodeId: String,
        order: PodcastEpisodeOrder,
        behavior: PodcastEpisodeEndBehavior,
        isFinished: (String) -> Bool
    ) -> ABSEpisodeDTO? {
        switch behavior {
        case .stop:
            return nil

        case .nextUnplayed:
            guard let current = episodes.first(where: { $0.id == currentEpisodeId }),
                  let currentDate = pubDate(current) else { return nil }
            return episodes
                .compactMap { ep -> (ABSEpisodeDTO, Date)? in
                    guard let d = pubDate(ep), d > currentDate else { return nil }
                    return (ep, d)
                }
                .filter { !isFinished($0.0.id) }
                .min { $0.1 < $1.1 }?
                .0

        case .continueInSortOrder:
            let ordered = sortedEpisodes(episodes, order: order)
            guard let pos = ordered.firstIndex(where: { $0.id == currentEpisodeId }) else { return nil }
            return ordered[ordered.index(after: pos)...].first { !isFinished($0.id) }
        }
    }

    /// Instance convenience over this context's own `episodes`/`order`.
    public func nextEpisode(
        after currentEpisodeId: String,
        behavior: PodcastEpisodeEndBehavior,
        isFinished: (String) -> Bool
    ) -> ABSEpisodeDTO? {
        Self.nextEpisode(in: episodes, after: currentEpisodeId, order: order, behavior: behavior, isFinished: isFinished)
    }

    /// Small tolerance (as a 0.0-1.0 progress fraction) for "close enough to
    /// the end to count as finished" — ABS's own `isFinished` flag is
    /// authoritative when present, but a progress record can land a hair
    /// under 1.0 (e.g. the last sync before the file's `.ended` event fires)
    /// without the flag ever having been set server-side. `ABSMediaProgressDTO`
    /// carries `progress` as a fraction, not raw seconds + duration, so the
    /// epsilon is fractional too.
    static let finishedProgressEpsilon: Double = 0.01

    /// Whether a hydrated progress record counts as "finished" for auto-play
    /// skip-played purposes: the server's own flag, OR `progress` within
    /// `finishedProgressEpsilon` of 1.0. `nil` progress (never started, or a
    /// failed/absent fetch) is unplayed — never finished. Pure.
    public static func isFinished(_ progress: ABSMediaProgressDTO?) -> Bool {
        guard let progress else { return false }
        if progress.isFinished == true { return true }
        if let fraction = progress.progress {
            return fraction >= 1.0 - finishedProgressEpsilon
        }
        return false
    }
}

// MARK: - Podcast browsing (E3 / c2s.2, c2s.3, c2s.4)

/// A podcast show summary for the "By Show" grid — just enough to render a
/// row/tile and open the show's episode list. Distinct from `Audiobook`
/// (which is a GRDB-persisted book record) — shows are not cached to the
/// local DB, they're re-fetched per library load like the book list is.
public struct PodcastShow: Equatable, Identifiable {
    public let id: String              // library item id
    public let libraryId: String
    public let title: String
    public let author: String?

    public init(id: String, libraryId: String, title: String, author: String?) {
        self.id = id
        self.libraryId = libraryId
        self.title = title
        self.author = author
    }

    /// Builds a show summary from a library item. `nil` if the item has no
    /// title (shouldn't happen for a real podcast, but keeps this total).
    public init?(item: ABSLibraryItemDTO, libraryIdFallback: String) {
        guard let title = item.showTitle else { return nil }
        self.id = item.id
        self.libraryId = item.libraryId ?? libraryIdFallback
        self.title = title
        self.author = item.media?.metadata?.displayAuthor
    }
}

/// One episode plus the show it belongs to — the unit rendered by the
/// "Recent Episodes" flat list and the Continue Listening shelf's episode
/// entries. Carries just enough of the show for row display + resuming
/// playback (`showLibraryItemId` is what `playPodcastEpisode` needs).
public struct PodcastEpisodeEntry: Equatable, Identifiable {
    public let episode: ABSEpisodeDTO
    public let showLibraryItemId: String
    public let showTitle: String?

    /// Per-episode progress fetched separately from `GET /api/me/progress/
    /// {libraryItemId}/{episodeId}`. ABS embeds episode progress NOWHERE in the
    /// episode object itself — neither `media.episodes[]` (item detail) nor
    /// `recentEpisode` (items-in-progress) carry `userMediaProgress`; progress
    /// lives only in the user's `mediaProgress[]`, keyed by (item, episode). So
    /// this is the only real source, hydrated after the fact. `nil` until
    /// hydrated (or when the episode has never been started → server 404s).
    public let hydratedProgress: ABSMediaProgressDTO?

    public var id: String { episode.id }

    public init(episode: ABSEpisodeDTO, showLibraryItemId: String, showTitle: String?, hydratedProgress: ABSMediaProgressDTO? = nil) {
        self.episode = episode
        self.showLibraryItemId = showLibraryItemId
        self.showTitle = showTitle
        self.hydratedProgress = hydratedProgress
    }

    public static func == (lhs: PodcastEpisodeEntry, rhs: PodcastEpisodeEntry) -> Bool {
        lhs.episode.id == rhs.episode.id
            && lhs.showLibraryItemId == rhs.showLibraryItemId
            && lhs.hydratedProgress?.progress == rhs.hydratedProgress?.progress
            && lhs.hydratedProgress?.isFinished == rhs.hydratedProgress?.isFinished
    }

    /// Returns a copy carrying `progress` as the authoritative source. Pure —
    /// the seam `loadInProgress` and its test both call through. Passing `nil`
    /// (the server's 404 for a never-started episode) leaves the entry unplayed.
    public func withProgress(_ progress: ABSMediaProgressDTO?) -> PodcastEpisodeEntry {
        PodcastEpisodeEntry(episode: episode, showLibraryItemId: showLibraryItemId, showTitle: showTitle, hydratedProgress: progress)
    }

    /// The authoritative progress record: the separately-fetched
    /// `hydratedProgress` if present, else the (in practice always-nil) embedded
    /// one, so By-Show rows that never hydrate simply read as unplayed rather
    /// than showing a fabricated value.
    private var activeProgress: ABSMediaProgressDTO? { hydratedProgress ?? episode.userMediaProgress }

    /// Progress fraction 0.0-1.0 for the badge/bar.
    public var progress: Double { activeProgress?.progress ?? 0 }
    public var isFinished: Bool { activeProgress?.isFinished ?? false }
    /// Absolute resume position in seconds — what a Continue-Listening tap
    /// passes to `playPodcastEpisode(startGlobalTime:)`. `nil` when unplayed.
    public var resumeTime: Double? { activeProgress?.currentTime }
    /// True when the episode has never been started — drives the unplayed badge.
    public var isUnplayed: Bool { !isFinished && progress <= 0 }
}

extension PodcastPlaybackContext {

    /// Parses an ABS `pubDate` ("Mon, 02 Jan 2006 15:04:05 GMT", RFC-2822) to a
    /// `Date`. `nil` when absent/unparseable. Pure — the ONE pubDate parser
    /// (sorting AND the row's display formatter both route through it, so the
    /// format string can't drift between them).
    public static func parsePubDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: raw)
    }

    static func pubDate(_ episode: ABSEpisodeDTO) -> Date? { parsePubDate(episode.pubDate) }

    /// Sorts a show's episodes per `order`. Pure — the single seam c2s.2's
    /// episode list (By Show + Recent Episodes), c2s.4's setting, and (via
    /// `nextEpisode`) whole-show auto-play all call through, so display order
    /// and auto-play direction can never disagree.
    ///
    /// Sorts EXPLICITLY by parsed `pubDate` — ABS's `media.episodes[]`
    /// association order is insertion/PK order, NOT guaranteed chronological
    /// (no `ORDER BY publishedAt` in `toOldJSONExpanded`), so reversing wire
    /// order could mislabel newest/oldest. Episodes with a missing/unparseable
    /// `pubDate` sort LAST in a stable way (their relative wire order is kept),
    /// so the order is total and tests are deterministic.
    public static func sortedEpisodes(_ episodes: [ABSEpisodeDTO], order: PodcastEpisodeOrder) -> [ABSEpisodeDTO] {
        let indexed = episodes.enumerated().map { ($0.offset, $0.element) }
        let sorted = indexed.sorted { lhs, rhs in
            let ld = pubDate(lhs.1), rd = pubDate(rhs.1)
            switch (ld, rd) {
            case let (l?, r?) where l != r:
                return order == .newestFirst ? l > r : l < r
            case (nil, _?):
                return false          // undated sorts after dated
            case (_?, nil):
                return true           // dated sorts before undated
            default:
                return lhs.0 < rhs.0  // equal dates / both undated → stable by wire order
            }
        }
        return sorted.map(\.1)
    }
}

/// Aggregates every show's episodes into one flat list for the "Recent
/// Episodes" browse mode (c2s.2). Pure — no network/DB.
///
/// Each show's episodes are sorted by `sortedEpisodes` (explicit `pubDate`
/// order), then shows are folded together in the order given. So each show is
/// internally chronological, but shows are NOT interleaved by date across the
/// library.
///
/// ponytail: no cross-show chronological interleaving — episodes cluster by
/// show. True library-wide "most recent across all shows" would flatten first
/// then `sortedEpisodes` the whole set; add that only if the grouped layout
/// proves unwanted. O(n log n) per show is fine at library scale.
public enum PodcastRecentEpisodes {
    public static func aggregate(shows: [(show: PodcastShow, episodes: [ABSEpisodeDTO])], order: PodcastEpisodeOrder) -> [PodcastEpisodeEntry] {
        let entries = shows.flatMap { pair in
            PodcastPlaybackContext.sortedEpisodes(pair.episodes, order: order).map {
                PodcastEpisodeEntry(episode: $0, showLibraryItemId: pair.show.id, showTitle: pair.show.title)
            }
        }
        return entries
    }
}

// MARK: - Continue Listening: books vs. podcast episodes (E3 / c2s.3)

/// `GET /api/me/items-in-progress` returns both in-progress books and podcast
/// episodes in one list. ABS sends an in-progress podcast as a MINIFIED show
/// item (`numEpisodes`, NO `media.episodes[]`) with the played episode under
/// a TOP-LEVEL `recentEpisode` field. A book item has no `recentEpisode`. So
/// `recentEpisode != nil` is the exact, unambiguous discriminator ABS itself
/// uses — not an episode-count heuristic (which a single-file audiobook or a
/// one-episode show could trip).
public enum PodcastContinueListening {

    /// Splits a mixed items-in-progress response into books and podcast
    /// episodes, preserving server order within each group. Pure — the single
    /// seam c2s.3's shelf and its tests both go through.
    ///
    /// Podcast episode ⇔ `item.recentEpisode != nil`. `recentEpisode` carries NO
    /// progress (ABS's `episode.toOldJSON` omits it), so each entry's progress is
    /// hydrated separately by `AudiobookshelfLibraryViewModel.loadInProgress` via
    /// `GET /api/me/progress/{item}/{episode}` — see `PodcastEpisodeEntry
    /// .withProgress`. Everything else is a book, subject to the same
    /// started/not-finished filter as before.
    public static func partition(items: [ABSLibraryItemDTO], updatedAt: Int) -> (books: [Audiobook], episodes: [PodcastEpisodeEntry]) {
        var books: [Audiobook] = []
        var episodes: [PodcastEpisodeEntry] = []
        for item in items {
            if let episode = item.recentEpisode {
                episodes.append(PodcastEpisodeEntry(episode: episode, showLibraryItemId: item.id, showTitle: item.showTitle))
            } else {
                let record = item.toRecord(libraryIdFallback: item.libraryId ?? "", updatedAt: updatedAt)
                if !record.isFinished && record.progress > 0 {
                    books.append(record)
                }
            }
        }
        return (books, episodes)
    }
}
