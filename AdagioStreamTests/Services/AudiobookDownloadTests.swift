import XCTest
import GRDB
@testable import AdagioStream

// Audiobookshelf E3 — offline download + batched progress sync.
// The smallest checks that fail if the timeline-reconstruction, task-mapping,
// startOffset math, or offline progress-queue logic break.

// MARK: - mkj.1: task-description mapping + offset math + timeline rebuild

final class AudiobookDownloadTests: XCTestCase {

    // Task-description round-trips and disambiguates from music trackIDs.

    func testBookTaskDescriptionRoundTrips() {
        let desc = DownloadManager.bookTaskDescription(bookID: "li_abc", ino: "649644248522215260")
        let parsed = DownloadManager.parseBookTaskDescription(desc)
        XCTAssertEqual(parsed?.bookID, "li_abc")
        XCTAssertEqual(parsed?.ino, "649644248522215260")
    }

    func testPlainTrackIDIsNotParsedAsBook() {
        XCTAssertNil(DownloadManager.parseBookTaskDescription("track-123"),
                     "A bare music trackID must not be mistaken for a book file")
    }

    func testBookIDWithHashInInoStillParses() {
        // ino has no '#', but maxSplits keeps a defensive tail intact.
        let desc = DownloadManager.bookTaskDescription(bookID: "book1", ino: "ino#weird")
        let parsed = DownloadManager.parseBookTaskDescription(desc)
        XCTAssertEqual(parsed?.bookID, "book1")
        XCTAssertEqual(parsed?.ino, "ino#weird")
    }

    // startOffset = cumulative sum of preceding file durations (mirrors ABS).

    func testCumulativeStartOffsets() {
        let durations = [100.0, 200.0, 50.0]
        var offset = 0.0
        var files: [AudiobookDownloadFile] = []
        for (i, d) in durations.enumerated() {
            files.append(AudiobookDownloadFile(index: i, ino: "\(i)", startOffset: offset, duration: d))
            offset += d
        }
        XCTAssertEqual(files.map(\.startOffset), [0, 100, 300])
        XCTAssertEqual(offset, 350, "total duration is the sum")
    }

    // ymf.4: manifest offsets come from the /play session's audioTracks
    // (server-authoritative), joined to each file's ino by index — NOT recomputed
    // from audioFiles durations (which include exclude'd files).

    private func session(json: String) -> ABSPlaybackSessionDTO {
        try! JSONDecoder().decode(ABSPlaybackSessionDTO.self, from: Data(json.utf8))
    }
    private func audioFiles(json: String) -> [ABSAudioFileDTO] {
        try! JSONDecoder().decode([ABSAudioFileDTO].self, from: Data(json.utf8))
    }

    func testDownloadFilesUsesServerStartOffsets() {
        // Play session already dropped an exclude'd file: audioFiles has 3 entries
        // (indices 0,1,2), tracks has 2 (indices 0,2) with server offsets 0 and 100.
        // Cumulative-summing audioFiles would put file 2 at 300, not 100.
        let s = session(json: """
        {"id":"s","playMethod":0,"audioTracks":[
          {"index":0,"startOffset":0,"duration":100,"contentUrl":"/a"},
          {"index":2,"startOffset":100,"duration":50,"contentUrl":"/c"}
        ]}
        """)
        let afs = audioFiles(json: """
        [{"index":0,"ino":"a","duration":100},
         {"index":1,"ino":"b","duration":200},
         {"index":2,"ino":"c","duration":50}]
        """)
        let files = AudiobookshelfLibraryViewModel.downloadFiles(session: s, audioFiles: afs)
        XCTAssertEqual(files?.map(\.index), [0, 2])
        XCTAssertEqual(files?.map(\.startOffset), [0, 100], "offsets are the server's, not a re-sum of audioFiles")
        XCTAssertEqual(files?.map(\.ino), ["a", "c"], "each track paired to its file ino by index")
    }

    func testDownloadFilesNilOnTranscode() {
        let s = session(json: """
        {"id":"s","playMethod":1,"audioTracks":[{"index":0,"startOffset":0,"duration":100,"contentUrl":"/x"}]}
        """)
        let afs = audioFiles(json: #"[{"index":0,"ino":"a","duration":100}]"#)
        XCTAssertNil(AudiobookshelfLibraryViewModel.downloadFiles(session: s, audioFiles: afs),
                     "a transcode session can't be downloaded per-file")
    }

    func testDownloadFilesNilWhenTrackHasNoIno() {
        // A track with no matching audioFile ino → hole in the offline timeline → bail.
        let s = session(json: """
        {"id":"s","playMethod":0,"audioTracks":[
          {"index":0,"startOffset":0,"duration":100,"contentUrl":"/a"},
          {"index":9,"startOffset":100,"duration":50,"contentUrl":"/z"}
        ]}
        """)
        let afs = audioFiles(json: #"[{"index":0,"ino":"a","duration":100}]"#)
        XCTAssertNil(AudiobookshelfLibraryViewModel.downloadFiles(session: s, audioFiles: afs))
    }

    // The persisted manifest rebuilds the SAME timeline as streaming would,
    // using local file paths as contentPath.

    func testTimelineReconstructionFromManifest() {
        let files = [
            AudiobookDownloadFile(index: 0, ino: "a", startOffset: 0,   duration: 100, localPath: "/x/a.audio"),
            AudiobookDownloadFile(index: 1, ino: "b", startOffset: 100, duration: 200, localPath: "/x/b.audio"),
        ]
        let chapters = [AudiobookChapter(id: "book#0", bookId: "book", title: "Ch1", start: 0, end: 150)]
        let record = AudiobookDownloadRecord(
            id: "book", title: "T", status: .completed,
            files: files, chapters: chapters, createdAt: 0, updatedAt: 0
        )
        let tl = record.timeline()

        XCTAssertEqual(tl.totalDuration, 300)
        // A global time of 120s lands in file b at 20s in — same math as streaming.
        let located = tl.locate(global: 120)
        XCTAssertEqual(located?.file.index, 1)
        XCTAssertEqual(located?.fileOffset ?? -1, 20, accuracy: 0.001)
        // contentPath is the LOCAL file path.
        XCTAssertEqual(located?.file.contentPath, "/x/b.audio")
        // Chapter mapping survives the round-trip.
        XCTAssertEqual(tl.chapter(at: 10)?.title, "Ch1")
    }

    func testTimelineSkipsFilesWithoutLocalPath() {
        // A half-downloaded book only exposes present files.
        let files = [
            AudiobookDownloadFile(index: 0, ino: "a", startOffset: 0, duration: 100, localPath: "/x/a.audio"),
            AudiobookDownloadFile(index: 1, ino: "b", startOffset: 100, duration: 200, localPath: nil),
        ]
        let record = AudiobookDownloadRecord(
            id: "book", title: "T", status: .downloading,
            files: files, chapters: [], createdAt: 0, updatedAt: 0
        )
        XCTAssertEqual(record.timeline().files.count, 1)
    }

    // MARK: Store round-trip (manifest JSON columns)

    func testStoreRoundTripPreservesManifest() throws {
        let store = try makeInMemoryNavidromeStore()
        let files = [
            AudiobookDownloadFile(index: 0, ino: "a", startOffset: 0, duration: 100, localPath: "/x/a.audio"),
            AudiobookDownloadFile(index: 1, ino: "b", startOffset: 100, duration: 200),
        ]
        let chapters = [AudiobookChapter(id: "b#0", bookId: "b", title: "C", start: 0, end: 50)]
        let record = AudiobookDownloadRecord(
            id: "b", title: "Book", author: "Auth", status: .downloading,
            files: files, chapters: chapters, createdAt: 1, updatedAt: 1
        )
        try store.upsert(audiobookDownload: record)

        let fetched = try store.audiobookDownload(forBook: "b")
        XCTAssertEqual(fetched?.files, files, "manifest must survive the JSON column round-trip")
        XCTAssertEqual(fetched?.chapters, chapters)
        XCTAssertEqual(fetched?.author, "Auth")
        XCTAssertEqual(fetched?.status, .downloading)
    }

    func testInvalidStatusRejectedByCheckConstraint() throws {
        let store = try makeInMemoryNavidromeStore()
        XCTAssertThrowsError(try store.writer.write { db in
            try db.execute(sql: """
                INSERT INTO audiobook_downloads (id, title, status, filesJSON, chaptersJSON, createdAt, updatedAt)
                VALUES ('x', 't', 'archived', '[]', '[]', 0, 0)
                """)
        })
    }
}

// MARK: - mkj.2: offline progress queue merge + flush

final class ABSProgressSyncQueueTests: XCTestCase {

    private func makeUpdate(_ id: String, currentTime: Double, duration: Double = 1000, lastUpdate: Int64) -> ABSProgressUpdate {
        ABSProgressUpdate(libraryItemId: id, currentTime: currentTime, duration: duration, lastUpdate: lastUpdate)
    }

    func testProgressFractionComputedFromTime() {
        let u = ABSProgressUpdate(libraryItemId: "b", currentTime: 250, duration: 1000)
        XCTAssertEqual(u.progress, 0.25, accuracy: 0.0001)
    }

    func testProgressFractionZeroWhenNoDuration() {
        let u = ABSProgressUpdate(libraryItemId: "b", currentTime: 250, duration: 0)
        XCTAssertEqual(u.progress, 0)
    }

    // Merge keeps ONE entry per book — the newest.

    func testMergeReplacesOlderProgressForSameBook() {
        let first  = makeUpdate("b", currentTime: 100, lastUpdate: 1)
        let second = makeUpdate("b", currentTime: 200, lastUpdate: 2)
        let merged = ABSProgressSyncQueue.merge([first], with: second)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].currentTime, 200, "newer progress wins")
    }

    func testMergeDropsStaleProgress() {
        let newer = makeUpdate("b", currentTime: 200, lastUpdate: 5)
        let stale = makeUpdate("b", currentTime: 50, lastUpdate: 2)
        let merged = ABSProgressSyncQueue.merge([newer], with: stale)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].currentTime, 200, "a late stale update must not rewind progress")
    }

    func testMergeKeepsDistinctBooks() {
        let a = makeUpdate("a", currentTime: 10, lastUpdate: 1)
        let b = makeUpdate("b", currentTime: 20, lastUpdate: 1)
        let merged = ABSProgressSyncQueue.merge([a], with: b)
        XCTAssertEqual(Set(merged.map(\.libraryItemId)), ["a", "b"])
    }

    // Enqueue persists and dedupes across an actor round-trip; a fresh queue
    // pointed at the same file reloads the pending items.

    func testEnqueuePersistsAndReloads() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("abs-queue-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let queue = ABSProgressSyncQueue(fileURL: tmp)
        await queue.enqueue(makeUpdate("b1", currentTime: 30, lastUpdate: 1))
        await queue.enqueue(makeUpdate("b1", currentTime: 90, lastUpdate: 2))  // supersedes
        await queue.enqueue(makeUpdate("b2", currentTime: 5, lastUpdate: 1))

        let reloaded = ABSProgressSyncQueue(fileURL: tmp)
        let snapshot = await reloaded.snapshot()
        XCTAssertEqual(snapshot.count, 2, "b1 collapsed to one entry, b2 kept")
        let b1 = snapshot.first { $0.libraryItemId == "b1" }
        XCTAssertEqual(b1?.currentTime, 90)
    }

    // pendingPosition reads one book's queued offline position (ymf.6 resume seed).

    func testPendingPositionReturnsQueuedTime() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("abs-queue-pos-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let queue = ABSProgressSyncQueue(fileURL: tmp)
        await queue.enqueue(makeUpdate("b1", currentTime: 815, lastUpdate: 1))
        let pos = await queue.pendingPosition(forBook: "b1")
        XCTAssertEqual(pos, 815)
        let none = await queue.pendingPosition(forBook: "b2")
        XCTAssertNil(none, "no pending entry → nil")
    }

    func testEmptyQueueFlushIsTrivialSuccess() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("abs-queue-empty-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let queue = ABSProgressSyncQueue(fileURL: tmp)
        let api = AudiobookshelfAPI(
            host: URL(string: "http://localhost")!,
            auth: AudiobookshelfAuth(host: URL(string: "http://localhost")!, username: "u", password: "p", providerID: "pid")
        )
        let ok = await queue.flush(via: api)
        XCTAssertTrue(ok, "flushing an empty queue is a no-op success")
    }
}

// MARK: - yha.1 / yha.4: podcast episode progress adapter + keyed dedup

final class ABSEpisodeProgressKeyTests: XCTestCase {

    // Books-unchanged: episodeId nil, and JSON encodes with no episodeId key at all.

    func testBookKeyHasNilEpisodeIdAndBookPaths() {
        let key = ABSEpisodeProgressKey(libraryItemId: "book-1")
        XCTAssertNil(key.episodeId)
        XCTAssertEqual(key.playPath, "/api/items/book-1/play")
        XCTAssertEqual(key.progressPath, "/api/me/progress/book-1")
    }

    func testBookProgressUpdateEncodesWithNoEpisodeIdField() throws {
        let update = ABSProgressUpdate(libraryItemId: "book-1", currentTime: 100, duration: 1000)
        XCTAssertNil(update.episodeId)

        let data = try JSONEncoder().encode(update)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(obj)
        // A book's payload must not carry an episodeId key at all — not even null —
        // so it serializes exactly as it did before podcasts existed.
        XCTAssertNil(obj?["episodeId"] as Any? ?? nil, "book payload must omit episodeId")
        XCTAssertFalse(obj?.keys.contains("episodeId") ?? true)
    }

    func testEpisodeKeyBuildsEpisodeScopedPaths() {
        let key = ABSEpisodeProgressKey(libraryItemId: "show-1", episodeId: "ep-1")
        XCTAssertEqual(key.playPath, "/api/items/show-1/play/ep-1")
        XCTAssertEqual(key.progressPath, "/api/me/progress/show-1/ep-1")
    }

    func testEpisodeProgressUpdateCarriesEpisodeId() {
        let key = ABSEpisodeProgressKey(libraryItemId: "show-1", episodeId: "ep-1")
        let update = key.progressUpdate(currentTime: 500, duration: 1800)
        XCTAssertEqual(update.libraryItemId, "show-1")
        XCTAssertEqual(update.episodeId, "ep-1")
        XCTAssertEqual(update.progress, 500.0 / 1800.0, accuracy: 0.0001)
    }

    // merge()/dedup keyed on (libraryItemId, episodeId?) — two episodes of the
    // same show must not collide into one queue entry.

    func testMergeKeepsDistinctEpisodesOfSameShow() {
        let ep1 = ABSProgressUpdate(libraryItemId: "show-1", episodeId: "ep-1", currentTime: 100, duration: 1800, lastUpdate: 1)
        let ep2 = ABSProgressUpdate(libraryItemId: "show-1", episodeId: "ep-2", currentTime: 200, duration: 2400, lastUpdate: 1)
        let merged = ABSProgressSyncQueue.merge([ep1], with: ep2)
        XCTAssertEqual(merged.count, 2, "same libraryItemId, different episodeId — must not collapse")
        XCTAssertEqual(Set(merged.map(\.episodeId)), ["ep-1", "ep-2"])
    }

    func testMergeReplacesOlderProgressForSameEpisode() {
        let first  = ABSProgressUpdate(libraryItemId: "show-1", episodeId: "ep-1", currentTime: 100, duration: 1800, lastUpdate: 1)
        let second = ABSProgressUpdate(libraryItemId: "show-1", episodeId: "ep-1", currentTime: 300, duration: 1800, lastUpdate: 2)
        let merged = ABSProgressSyncQueue.merge([first], with: second)
        XCTAssertEqual(merged.count, 1, "same show AND same episode — collapses like a book does")
        XCTAssertEqual(merged[0].currentTime, 300)
    }

    func testMergeDoesNotConfuseShowLevelAndEpisodeLevelEntries() {
        // A book/show-level update (episodeId nil) and an episode update that
        // happens to share libraryItemId must stay distinct.
        let showLevel = ABSProgressUpdate(libraryItemId: "show-1", currentTime: 10, duration: 100, lastUpdate: 1)
        let episode = ABSProgressUpdate(libraryItemId: "show-1", episodeId: "ep-1", currentTime: 50, duration: 1800, lastUpdate: 1)
        let merged = ABSProgressSyncQueue.merge([showLevel], with: episode)
        XCTAssertEqual(merged.count, 2)
    }
}
