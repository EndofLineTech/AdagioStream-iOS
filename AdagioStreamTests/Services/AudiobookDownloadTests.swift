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
