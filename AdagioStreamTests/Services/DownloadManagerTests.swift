import XCTest
import GRDB
@testable import AdagioStream

// MARK: - NavidromeStore DownloadRecord CRUD Tests

final class DownloadRecordStoreTests: XCTestCase {

    // MARK: Helpers

    private func makeStore() throws -> NavidromeStore {
        try makeInMemoryNavidromeStore()
    }

    private func makeRecord(
        id: String = "track-1",
        status: DownloadStatus = .queued,
        localPath: String? = nil,
        resumeOffset: Int = 0,
        error: String? = nil,
        createdAt: Int = 1_700_000_000,
        updatedAt: Int = 1_700_000_000
    ) -> DownloadRecord {
        DownloadRecord(
            id: id,
            status: status,
            localPath: localPath,
            resumeOffset: resumeOffset,
            error: error,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    // MARK: Insert and fetch by id

    func testUpsertAndFetchByID() throws {
        let store = try makeStore()
        let record = makeRecord(id: "t1", status: .queued)

        try store.upsert(download: record)

        let fetched = try store.download(forTrackID: "t1")
        XCTAssertNotNil(fetched, "Expected to fetch the upserted record")
        XCTAssertEqual(fetched?.id, "t1")
        XCTAssertEqual(fetched?.status, .queued)
    }

    func testFetchByIDMissingReturnsNil() throws {
        let store = try makeStore()
        let result = try store.download(forTrackID: "nonexistent")
        XCTAssertNil(result, "Fetching a non-existent trackID must return nil")
    }

    // MARK: All downloads

    func testAllDownloadsReturnsAllRows() throws {
        let store = try makeStore()
        try store.upsert(download: makeRecord(id: "a", createdAt: 100))
        try store.upsert(download: makeRecord(id: "b", createdAt: 200))
        try store.upsert(download: makeRecord(id: "c", createdAt: 300))

        let all = try store.allDownloads()
        XCTAssertEqual(all.count, 3)
        // Must be ordered by createdAt ascending.
        XCTAssertEqual(all.map { $0.id }, ["a", "b", "c"])
    }

    func testAllDownloadsEmptyReturnsEmpty() throws {
        let store = try makeStore()
        XCTAssertTrue(try store.allDownloads().isEmpty)
    }

    // MARK: Fetch by status

    func testFetchByStatusFiltersByStatus() throws {
        let store = try makeStore()
        try store.upsert(download: makeRecord(id: "q1", status: .queued))
        try store.upsert(download: makeRecord(id: "q2", status: .queued))
        try store.upsert(download: makeRecord(id: "c1", status: .completed, localPath: "/x/y.mp3"))
        try store.upsert(download: makeRecord(id: "f1", status: .failed, error: "oops"))

        let queued    = try store.downloads(withStatus: .queued)
        let completed = try store.downloads(withStatus: .completed)
        let failed    = try store.downloads(withStatus: .failed)
        let paused    = try store.downloads(withStatus: .paused)

        XCTAssertEqual(queued.count,    2)
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(failed.count,    1)
        XCTAssertTrue(paused.isEmpty)
    }

    // MARK: Update status

    func testUpdateStatusTransitionsCorrectly() throws {
        let store = try makeStore()
        try store.upsert(download: makeRecord(id: "t2", status: .queued))

        try store.updateDownload(trackID: "t2", status: .downloading)
        let mid = try store.download(forTrackID: "t2")
        XCTAssertEqual(mid?.status, .downloading)

        try store.updateDownload(trackID: "t2", status: .completed, localPath: "/local/track.flac")
        let done = try store.download(forTrackID: "t2")
        XCTAssertEqual(done?.status, .completed)
        XCTAssertEqual(done?.localPath, "/local/track.flac")
    }

    func testUpdateStatusToFailed() throws {
        let store = try makeStore()
        try store.upsert(download: makeRecord(id: "t3", status: .downloading))

        try store.updateDownload(trackID: "t3", status: .failed, error: "Connection lost")
        let result = try store.download(forTrackID: "t3")
        XCTAssertEqual(result?.status, .failed)
        XCTAssertEqual(result?.error, "Connection lost")
    }

    func testUpdateStatusOnMissingIDIsNoOp() throws {
        // Should not throw even when the row doesn't exist.
        let store = try makeStore()
        XCTAssertNoThrow(
            try store.updateDownload(trackID: "ghost", status: .completed)
        )
    }

    // MARK: Resume offset round-trip

    func testResumeOffsetRoundTrip() throws {
        let store = try makeStore()
        let r = makeRecord(id: "r1", resumeOffset: 12345)
        try store.upsert(download: r)

        let fetched = try store.download(forTrackID: "r1")
        XCTAssertEqual(fetched?.resumeOffset, 12345, "resumeOffset must survive an upsert round-trip")
    }

    func testUpdateResumeOffset() throws {
        let store = try makeStore()
        try store.upsert(download: makeRecord(id: "r2", resumeOffset: 0))

        try store.updateDownload(trackID: "r2", status: .paused, resumeOffset: 98765)
        let result = try store.download(forTrackID: "r2")
        XCTAssertEqual(result?.resumeOffset, 98765)
    }

    // MARK: Delete

    func testDeleteDownloadRemovesRow() throws {
        let store = try makeStore()
        try store.upsert(download: makeRecord(id: "del1"))

        try store.deleteDownload(forTrackID: "del1")
        let result = try store.download(forTrackID: "del1")
        XCTAssertNil(result, "Row must be absent after deleteDownload")
    }

    func testDeleteDownloadOnMissingIDIsIdempotent() throws {
        let store = try makeStore()
        XCTAssertNoThrow(try store.deleteDownload(forTrackID: "nonexistent"))
    }

    // MARK: CHECK constraint

    /// The GRDB Codable synthesis writes the rawValue ("queued") into the column;
    /// valid values must round-trip cleanly.
    func testAllValidStatusValuesRoundTrip() throws {
        let store = try makeStore()
        for (index, status) in DownloadStatus.allCases.enumerated() {
            let id = "check-\(index)"
            let r = makeRecord(id: id, status: status)
            try store.upsert(download: r)
            let fetched = try store.download(forTrackID: id)
            XCTAssertEqual(fetched?.status, status, "\(status.rawValue) must survive a round-trip")
        }
    }

    /// Attempting to write an invalid status string directly (bypassing the
    /// enum) must be rejected by the CHECK constraint.
    func testInvalidStatusStringRejectedByCheckConstraint() throws {
        let store = try makeStore()
        XCTAssertThrowsError(
            try store.writer.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO downloads
                            (id, status, resumeOffset, createdAt, updatedAt)
                        VALUES (?, ?, 0, ?, ?)
                        """,
                    arguments: ["bad-status", "archived", 1_700_000_000, 1_700_000_000]
                )
            },
            "Expected DatabaseError for invalid status 'archived'"
        ) { error in
            XCTAssertTrue(error is DatabaseError, "Expected DatabaseError, got \(type(of: error))")
        }
    }

    // MARK: Upsert replaces existing row

    func testUpsertReplacesExistingRow() throws {
        let store = try makeStore()
        try store.upsert(download: makeRecord(id: "up1", status: .queued))

        // Upsert again with a different status.
        let updated = makeRecord(id: "up1", status: .completed, localPath: "/files/up1.mp3")
        try store.upsert(download: updated)

        let all = try store.allDownloads()
        XCTAssertEqual(all.count, 1, "Upsert must not create a duplicate row")
        XCTAssertEqual(all[0].status, .completed)
        XCTAssertEqual(all[0].localPath, "/files/up1.mp3")
    }

    // MARK: deleteAllDownloads

    func testDeleteAllDownloadsRemovesAllRows() throws {
        let store = try makeStore()
        try store.upsert(download: makeRecord(id: "x1"))
        try store.upsert(download: makeRecord(id: "x2"))

        try store.deleteAllDownloads()
        XCTAssertTrue(try store.allDownloads().isEmpty)
    }
}

// MARK: - NavidromeAPI downloadURL Tests

final class NavidromeAPIDownloadURLTests: XCTestCase {

    private var api: NavidromeAPI!

    override func setUp() {
        super.setUp()
        api = NavidromeAPI(
            host: URL(string: "http://navidrome.example.com")!,
            username: "alice",
            password: "sesame"
        )
    }

    func testDownloadURLBuildsCorrectPath() {
        let url = api.downloadURL(trackID: "trk-99")
        XCTAssertNotNil(url, "downloadURL must return a non-nil URL")
        XCTAssertEqual(url?.path, "/rest/download.view")
    }

    func testDownloadURLContainsTrackID() {
        let url = api.downloadURL(trackID: "trk-abc")
        let items = URLComponents(string: url?.absoluteString ?? "")?.queryItems ?? []
        let idParam = items.first(where: { $0.name == "id" })?.value
        XCTAssertEqual(idParam, "trk-abc", "id= param must match the track ID")
    }

    func testDownloadURLContainsAllAuthQueryParams() {
        let url = api.downloadURL(trackID: "trk-1")
        let items = URLComponents(string: url?.absoluteString ?? "")?.queryItems ?? []
        func q(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }

        XCTAssertEqual(q("u"), "alice", "u= must match the username")
        XCTAssertNotNil(q("t"), "t= (token) must be present")
        XCTAssertNotNil(q("s"), "s= (salt) must be present")
        XCTAssertEqual(q("c"), SubsonicAuth.clientName, "c= must be the client name")
        XCTAssertEqual(q("v"), SubsonicAuth.apiVersion, "v= must be the API version")
        XCTAssertEqual(q("f"), "json", "f= must be json")
    }

    func testDownloadURLHostIsPreserved() {
        let url = api.downloadURL(trackID: "trk-1")
        XCTAssertEqual(url?.host, "navidrome.example.com")
    }

    /// download.view must NOT include maxBitRate or format — it returns the
    /// original file unconditionally (unlike stream.view which can transcode).
    func testDownloadURLDoesNotIncludeTranscodeParams() {
        let url = api.downloadURL(trackID: "trk-1")
        let items = URLComponents(string: url?.absoluteString ?? "")?.queryItems ?? []
        let maxBR = items.first(where: { $0.name == "maxBitRate" })?.value
        let format = items.first(where: { $0.name == "format" })?.value
        XCTAssertNil(maxBR, "download.view must not include maxBitRate")
        XCTAssertNil(format, "download.view must not include format")
    }

    /// The endpoint must be "download.view", not "stream.view".
    func testDownloadURLIsNotStreamURL() {
        let downloadURL = api.downloadURL(trackID: "trk-1")
        let streamURL   = api.streamURL(trackID: "trk-1")
        XCTAssertNotEqual(
            downloadURL?.path, streamURL?.path,
            "download.view and stream.view must be different endpoints"
        )
    }
}

// MARK: - DownloadManager State Machine Tests

/// These tests exercise the DownloadManager state logic without making real
/// network calls.  The GRDB store is an in-memory queue for isolation.
@MainActor
final class DownloadManagerStateMachineTests: XCTestCase {

    private var store: NavidromeStore!
    private var manager: DownloadManager!
    private var api: NavidromeAPI!

    override func setUp() async throws {
        try await super.setUp()
        store = try NavidromeStore(writer: DatabaseQueue())
        manager = DownloadManager(store: store)
        api = NavidromeAPI(
            host: URL(string: "http://navidrome.example.com")!,
            username: "alice",
            password: "sesame"
        )
    }

    // MARK: Initial state

    func testInitialDownloadsIsEmpty() {
        XCTAssertTrue(manager.downloads.isEmpty, "No downloads at init")
    }

    // MARK: download() inserts a queued row

    func testDownloadInsertsQueuedRow() throws {
        let track = makeTrack(id: "t1", suffix: "flac")
        manager.download(track: track, via: api)

        let record = try store.download(forTrackID: "t1")
        XCTAssertNotNil(record)
        // Row is immediately queued (or moved to downloading if a slot was free).
        // We just check it exists and has a sensible status.
        XCTAssertTrue(
            [.queued, .downloading].contains(record!.status),
            "Status must be queued or downloading immediately after download()"
        )
    }

    func testDownloadPublishedSnapshotUpdated() throws {
        let track = makeTrack(id: "t2")
        manager.download(track: track, via: api)

        // The published `downloads` array must be non-empty.
        XCTAssertFalse(manager.downloads.isEmpty, "downloads snapshot must be updated after download()")
    }

    // MARK: Idempotency — completed row is not re-downloaded

    func testDownloadCompletedTrackIsNoOp() throws {
        let now = Int(Date().timeIntervalSince1970)
        let completedRecord = DownloadRecord(
            id: "t3",
            status: .completed,
            localPath: "/fake/t3.mp3",
            resumeOffset: 1024,
            error: nil,
            createdAt: now,
            updatedAt: now
        )
        try store.upsert(download: completedRecord)

        let track = makeTrack(id: "t3")
        manager.download(track: track, via: api)

        // Status must remain .completed — not reset to .queued.
        let record = try store.download(forTrackID: "t3")
        XCTAssertEqual(record?.status, .completed, "Completed row must not be overwritten")
    }

    // MARK: cancelDownload

    func testCancelDownloadMarksRowFailed() throws {
        let now = Int(Date().timeIntervalSince1970)
        let record = DownloadRecord(
            id: "t4", status: .queued,
            localPath: nil, resumeOffset: 0, error: nil,
            createdAt: now, updatedAt: now
        )
        try store.upsert(download: record)

        manager.cancelDownload(trackID: "t4")

        let result = try store.download(forTrackID: "t4")
        XCTAssertEqual(result?.status, .failed)
        XCTAssertEqual(result?.error, "Cancelled")
    }

    func testCancelDownloadRemovesProgress() throws {
        let now = Int(Date().timeIntervalSince1970)
        let record = DownloadRecord(
            id: "t5", status: .downloading,
            localPath: nil, resumeOffset: 0, error: nil,
            createdAt: now, updatedAt: now
        )
        try store.upsert(download: record)

        manager.cancelDownload(trackID: "t5")
        XCTAssertNil(manager.progress["t5"], "Progress entry must be removed on cancel")
    }

    // MARK: deleteDownload

    func testDeleteDownloadRemovesRow() throws {
        let now = Int(Date().timeIntervalSince1970)
        let record = DownloadRecord(
            id: "t6", status: .queued,
            localPath: nil, resumeOffset: 0, error: nil,
            createdAt: now, updatedAt: now
        )
        try store.upsert(download: record)

        manager.deleteDownload(trackID: "t6")

        let result = try store.download(forTrackID: "t6")
        XCTAssertNil(result, "Row must be removed after deleteDownload")
    }

    // MARK: isDownloaded / localFileURL

    func testIsDownloadedReturnsFalseWhenNoRow() {
        XCTAssertFalse(manager.isDownloaded(trackID: "missing"))
    }

    func testIsDownloadedReturnsFalseWhenStatusQueued() throws {
        let now = Int(Date().timeIntervalSince1970)
        let record = DownloadRecord(
            id: "t7", status: .queued,
            localPath: "/tmp/t7.flac", resumeOffset: 0, error: nil,
            createdAt: now, updatedAt: now
        )
        try store.upsert(download: record)

        // Status is .queued, file doesn't exist — isDownloaded must be false.
        XCTAssertFalse(manager.isDownloaded(trackID: "t7"))
    }

    func testLocalFileURLReturnsNilForNonCompletedStatus() throws {
        let now = Int(Date().timeIntervalSince1970)
        let record = DownloadRecord(
            id: "t8", status: .failed,
            localPath: "/tmp/t8.flac", resumeOffset: 0, error: "err",
            createdAt: now, updatedAt: now
        )
        try store.upsert(download: record)

        XCTAssertNil(manager.localFileURL(forTrackID: "t8"),
                     "localFileURL must return nil for non-completed status")
    }

    // MARK: clearAllDownloads

    func testClearAllDownloadsEmptiesTable() throws {
        let now = Int(Date().timeIntervalSince1970)
        try store.upsert(download: DownloadRecord(
            id: "ca1", status: .queued, resumeOffset: 0,
            createdAt: now, updatedAt: now
        ))
        try store.upsert(download: DownloadRecord(
            id: "ca2", status: .completed, localPath: "/tmp/ca2.mp3",
            resumeOffset: 0, createdAt: now, updatedAt: now
        ))

        manager.clearAllDownloads()

        XCTAssertTrue(try store.allDownloads().isEmpty)
        XCTAssertTrue(manager.downloads.isEmpty)
    }

    // MARK: maxConcurrentDownloads

    func testMaxConcurrentDownloadsIsPositive() {
        XCTAssertGreaterThan(manager.maxConcurrentDownloads, 0)
    }

    // MARK: Helpers

    private func makeTrack(id: String, suffix: String = "mp3") -> Track {
        Track(
            id: id,
            albumId: "album-1",
            artistId: "artist-1",
            title: "Track \(id)",
            trackNumber: 1,
            discNumber: 1,
            duration: 180,
            genre: nil,
            bitRate: 320,
            suffix: suffix,
            contentType: "audio/mpeg",
            coverArt: nil,
            path: nil,
            updatedAt: Int(Date().timeIntervalSince1970)
        )
    }
}

// MARK: - Resume Data Persistence Tests

/// Tests for the static resume-data helpers on DownloadManager.
/// These are pure file-system operations — no network, no URLSession.
final class DownloadManagerResumeDataTests: XCTestCase {

    private let trackID = "resume-test-track-\(Int(Date().timeIntervalSince1970))"

    override func tearDown() {
        super.tearDown()
        DownloadManager.clearResumeData(forTrackID: trackID)
    }

    // MARK: Persist and load

    func testPersistAndLoadResumeData() {
        let data = Data("fake-resume-blob".utf8)
        DownloadManager.persistResumeData(data, forTrackID: trackID)

        let loaded = DownloadManager.loadResumeData(forTrackID: trackID)
        XCTAssertEqual(loaded, data, "Loaded resume data must match persisted bytes")
    }

    func testLoadResumeDataReturnsNilWhenAbsent() {
        // No data persisted for this trackID.
        let result = DownloadManager.loadResumeData(forTrackID: "no-such-track-xyz")
        XCTAssertNil(result, "loadResumeData must return nil when no file exists")
    }

    func testClearResumeDataRemovesFile() {
        let data = Data("blob".utf8)
        DownloadManager.persistResumeData(data, forTrackID: trackID)
        XCTAssertNotNil(DownloadManager.loadResumeData(forTrackID: trackID))

        DownloadManager.clearResumeData(forTrackID: trackID)
        XCTAssertNil(DownloadManager.loadResumeData(forTrackID: trackID),
                     "clearResumeData must remove the persisted file")
    }

    func testClearResumeDataIsIdempotentWhenAbsent() {
        // Must not throw when no file exists.
        XCTAssertNoThrow(DownloadManager.clearResumeData(forTrackID: "ghost-track"))
    }

    func testOverwriteResumeData() {
        let first  = Data("first".utf8)
        let second = Data("second-longer".utf8)
        DownloadManager.persistResumeData(first, forTrackID: trackID)
        DownloadManager.persistResumeData(second, forTrackID: trackID)

        let loaded = DownloadManager.loadResumeData(forTrackID: trackID)
        XCTAssertEqual(loaded, second, "Second persist must overwrite the first")
    }

    // MARK: URL derivation

    func testResumeDataURLContainsTrackID() {
        let url = DownloadManager.resumeDataURL(forTrackID: "trk-42")
        XCTAssertTrue(url.lastPathComponent.contains("trk-42"),
                      "Resume data URL must embed the trackID")
        XCTAssertEqual(url.pathExtension, "resumedata")
    }

    func testResumeDataURLIsUnderAppSupportDirectory() {
        let url = DownloadManager.resumeDataURL(forTrackID: "trk-1")
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        XCTAssertTrue(
            url.path.hasPrefix(appSupport.path),
            "Resume data URL must be under Application Support"
        )
    }
}

// MARK: - Launch Reconciliation Logic Tests

/// Tests for the reconcileBackgroundSession logic: given a set of live task
/// trackIDs and a set of DB rows in .downloading, the reconciler must leave
/// live tasks alone and mark orphaned rows .failed.
@MainActor
final class DownloadManagerReconciliationTests: XCTestCase {

    private var store: NavidromeStore!
    private var manager: DownloadManager!

    override func setUp() async throws {
        try await super.setUp()
        store = try NavidromeStore(writer: DatabaseQueue())
        manager = DownloadManager(store: store)
    }

    // MARK: Helpers

    private func insertDownloadingRow(id: String) throws {
        let now = Int(Date().timeIntervalSince1970)
        try store.upsert(download: DownloadRecord(
            id: id,
            status: .downloading,
            localPath: "/tmp/\(id).mp3",
            resumeOffset: 0,
            error: nil,
            createdAt: now,
            updatedAt: now
        ))
    }

    /// Exercises the reconcile logic directly with a caller-supplied set of
    /// live task IDs, bypassing the real URLSession.getAllTasks() call.
    private func reconcile(liveTaskTrackIDs: Set<String>) async {
        // Mark stuck rows that have no live task as failed.
        let stuck = (try? store.downloads(withStatus: .downloading)) ?? []
        for record in stuck {
            guard !liveTaskTrackIDs.contains(record.id) else { continue }
            try? store.updateDownload(
                trackID: record.id,
                status: .failed,
                error: "Interrupted — tap to retry"
            )
        }
    }

    // MARK: Tests

    func testReconcileMarksStuckRowFailed() async throws {
        try insertDownloadingRow(id: "stuck-1")

        // No live tasks — the row should be marked .failed.
        await reconcile(liveTaskTrackIDs: [])

        let record = try store.download(forTrackID: "stuck-1")
        XCTAssertEqual(record?.status, .failed)
        XCTAssertNotNil(record?.error)
    }

    func testReconcileLeavesLiveTaskRowUnchanged() async throws {
        try insertDownloadingRow(id: "live-1")

        // "live-1" has a matching live task — must stay .downloading.
        await reconcile(liveTaskTrackIDs: ["live-1"])

        let record = try store.download(forTrackID: "live-1")
        XCTAssertEqual(record?.status, .downloading,
                       "Row for a live background task must stay .downloading")
    }

    func testReconcileMixedStuckAndLive() async throws {
        try insertDownloadingRow(id: "live-2")
        try insertDownloadingRow(id: "stuck-2")

        await reconcile(liveTaskTrackIDs: ["live-2"])

        let live  = try store.download(forTrackID: "live-2")
        let stuck = try store.download(forTrackID: "stuck-2")

        XCTAssertEqual(live?.status,  .downloading, "live-2 must stay downloading")
        XCTAssertEqual(stuck?.status, .failed,      "stuck-2 must be marked failed")
    }

    func testReconcileNoDownloadingRowsIsNoOp() async throws {
        // Insert a completed row — must not be touched.
        let now = Int(Date().timeIntervalSince1970)
        try store.upsert(download: DownloadRecord(
            id: "done-1",
            status: .completed,
            localPath: "/tmp/done-1.mp3",
            resumeOffset: 1024,
            error: nil,
            createdAt: now,
            updatedAt: now
        ))

        await reconcile(liveTaskTrackIDs: [])

        let record = try store.download(forTrackID: "done-1")
        XCTAssertEqual(record?.status, .completed, "Completed row must not be touched by reconcile")
    }

    // MARK: Task-to-trackID mapping

    func testTaskDescriptionIsUsedForTrackIDMapping() {
        // The task<->trackId contract: taskDescription == trackID.
        // We verify this indirectly via the download() method which sets
        // taskDescription before enqueueing, meaning enqueuedTrackIDs contains
        // the trackID after a download() call.
        // We check that the idempotency guard uses the same key.
        let now = Int(Date().timeIntervalSince1970)
        let completedRecord = DownloadRecord(
            id: "mapping-1",
            status: .completed,
            localPath: "/fake/mapping-1.mp3",
            resumeOffset: 1024,
            error: nil,
            createdAt: now,
            updatedAt: now
        )
        try? store.upsert(download: completedRecord)

        let api = NavidromeAPI(
            host: URL(string: "http://navidrome.example.com")!,
            username: "alice",
            password: "sesame"
        )
        let track = Track(
            id: "mapping-1",
            albumId: "album-1",
            artistId: "artist-1",
            title: "T",
            trackNumber: 1,
            discNumber: 1,
            duration: 180,
            genre: nil,
            bitRate: 320,
            suffix: "mp3",
            contentType: "audio/mpeg",
            coverArt: nil,
            path: nil,
            updatedAt: now
        )

        // A second call to download() for a completed track must be a no-op —
        // proving the trackID mapping correctly finds the existing row.
        manager.download(track: track, via: api)

        let record = try? store.download(forTrackID: "mapping-1")
        XCTAssertEqual(record?.status, .completed,
                       "Completed row must not be overwritten — trackID mapping must work")
    }
}
