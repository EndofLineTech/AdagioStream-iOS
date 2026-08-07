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
        // Components are percent-encoded, so a '#' inside one round-trips.
        let desc = DownloadManager.bookTaskDescription(bookID: "book1", ino: "ino#weird")
        let parsed = DownloadManager.parseBookTaskDescription(desc)
        XCTAssertEqual(parsed?.bookID, "book1")
        XCTAssertEqual(parsed?.ino, "ino#weird")
    }

    // A plain book id + numeric ino encode to themselves — book task
    // descriptions stay byte-identical, so in-flight/resumed book tasks from an
    // older build still parse (no migration).
    func testPlainBookTaskDescriptionIsUnchangedOnTheWire() {
        XCTAssertEqual(
            DownloadManager.bookTaskDescription(bookID: "li_abc", ino: "649644248522215260"),
            "abs#li_abc#649644248522215260"
        )
    }

    // BUG 2 regression: an episode's composite record id contains '#', which the
    // old maxSplits(1) scheme could not round-trip. Percent-encoding fixes it.
    func testEpisodeTaskDescriptionRoundTrips() {
        let bookID = AudiobookDownloadRecord.episodeRecordID(showID: "show-1", episodeID: "ep-1")
        let desc = DownloadManager.bookTaskDescription(bookID: bookID, ino: "12345")
        let parsed = DownloadManager.parseBookTaskDescription(desc)
        XCTAssertEqual(parsed?.bookID, bookID, "the ep#<show>#<episode> id must survive the round-trip intact")
        XCTAssertEqual(parsed?.ino, "12345")
    }

    // BUG 1 regression: the file-download URL for an episode must hit the SHOW's
    // server item id, never the "ep#<show>#<episode>" DB record id (which 404s —
    // it isn't a real ABS library item).
    func testEpisodeFileDownloadURLUsesShowIDNotRecordID() {
        let recordID = AudiobookDownloadRecord.episodeRecordID(showID: "show-1", episodeID: "ep-1")
        let serverItemID = AudiobookDownloadRecord.serverItemID(forRecordID: recordID)
        XCTAssertEqual(serverItemID, "show-1")

        let api = AudiobookshelfAPI(
            host: URL(string: "http://localhost")!,
            auth: AudiobookshelfAuth(host: URL(string: "http://localhost")!, username: "u", password: "p", providerID: "pid")
        )
        let url = api.fileDownloadURL(itemID: serverItemID, ino: "12345")
        let urlString = url?.absoluteString ?? ""
        XCTAssertTrue(urlString.contains("/api/items/show-1/file/12345/download"), "got \(urlString)")
        XCTAssertFalse(urlString.contains("ep#"), "the server URL must never contain the ep# composite record id")
    }

    // A book's server item id IS its record id — no episode indirection.
    func testBookFileDownloadURLUsesRecordIDDirectly() {
        let serverItemID = AudiobookDownloadRecord.serverItemID(forRecordID: "li_abc")
        XCTAssertEqual(serverItemID, "li_abc")
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

    // MARK: - uxi: currentTime migration-safety + write funnel

    // Simulates a row persisted before the v6 "addAudiobookDownloadCurrentTime"
    // migration: an INSERT that never mentions the currentTime column. On a
    // real device this is exactly what ALTER TABLE ADD COLUMN produces for
    // every pre-existing row (NULL, not a decode error) — this pins that the
    // typed record decodes cleanly with currentTime == nil rather than
    // throwing or crashing.
    func testDecodeOldFormatRecordWithoutCurrentTimeLoadsCleanly() throws {
        let store = try makeInMemoryNavidromeStore()
        try store.writer.write { db in
            try db.execute(sql: """
                INSERT INTO audiobook_downloads (id, title, status, filesJSON, chaptersJSON, createdAt, updatedAt)
                VALUES ('legacy-book', 'Legacy', 'completed', '[]', '[]', 0, 0)
                """)
        }
        let fetched = try store.audiobookDownload(forBook: "legacy-book")
        XCTAssertNotNil(fetched, "a pre-uxi row must still fetch")
        XCTAssertNil(fetched?.currentTime, "absent currentTime decodes as nil, not a decode failure")
    }

    // The decode-old-format test above pins decode behavior on an
    // already-v6 schema (a v6 CREATE ran, so `currentTime` was declared but
    // simply never inserted). This one builds an ACTUAL pre-v6 database —
    // migrated only through v5 (createAudiobookDownloads), so
    // `audiobook_downloads` has no currentTime column at all — inserts
    // realistic rows, then runs the SAME shared migrator NavidromeStore uses
    // in production to bring it forward, and checks nothing was lost or
    // corrupted by the ALTER TABLE. `DatabaseMigrator.migrate(_:upTo:)` makes
    // `NavidromeStore.migrator` truncatable without hand-copying DDL.
    func testPreV6DatabaseMigratesCleanlyPreservingExistingRows() async throws {
        let queue = try DatabaseQueue()
        try NavidromeStore.migrator.migrate(queue, upTo: "createAudiobookDownloads")

        let filesJSON = #"[{"index":0,"ino":"a","startOffset":0,"duration":100,"localPath":"/x/a.audio"}]"#
        let chaptersJSON = #"[{"id":"book-1#0","bookId":"book-1","title":"Ch1","start":0,"end":100}]"#
        let episodeID = AudiobookDownloadRecord.episodeRecordID(showID: "show-1", episodeID: "ep-1")

        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO audiobook_downloads
                    (id, title, author, coverPath, duration, status, filesJSON, chaptersJSON, error, createdAt, updatedAt)
                VALUES (?, 'Book One', 'Author A', '/cover/1.jpg', 3600.5, 'completed', ?, ?, NULL, 1000, 2000)
                """, arguments: ["book-1", filesJSON, chaptersJSON])
            try db.execute(sql: """
                INSERT INTO audiobook_downloads
                    (id, title, author, coverPath, duration, status, filesJSON, chaptersJSON, error, createdAt, updatedAt)
                VALUES (?, 'Episode One', 'Show A', NULL, 900, 'downloading', '[]', '[]', NULL, 1500, 1500)
                """, arguments: [episodeID])
        }

        // Run the FULL migrator (adds v6's currentTime column) over the
        // pre-existing rows — mirrors what a real upgrading device does.
        try NavidromeStore.migrator.migrate(queue)
        let store = try NavidromeStore(writer: queue)

        let all = try store.allAudiobookDownloads()
        XCTAssertEqual(all.count, 2, "the ALTER TABLE must not drop or duplicate rows")

        let book = try store.audiobookDownload(forBook: "book-1")
        XCTAssertEqual(book?.title, "Book One")
        XCTAssertEqual(book?.author, "Author A")
        XCTAssertEqual(book?.coverPath, "/cover/1.jpg")
        XCTAssertEqual(book?.duration, 3600.5)
        XCTAssertEqual(book?.status, .completed)
        XCTAssertEqual(book?.files.first?.localPath, "/x/a.audio", "filesJSON survives byte-for-byte through the ALTER TABLE")
        XCTAssertEqual(book?.chapters.first?.title, "Ch1")
        XCTAssertEqual(book?.createdAt, 1000)
        XCTAssertEqual(book?.updatedAt, 2000)
        XCTAssertNil(book?.currentTime, "pre-existing rows backfill NULL, not 0 or a decode failure")

        let episode = try store.audiobookDownload(forBook: episodeID)
        XCTAssertEqual(episode?.title, "Episode One")
        XCTAssertEqual(episode?.status, .downloading)
        XCTAssertNil(episode?.currentTime)

        // A subsequent targeted currentTime UPDATE round-trips on a migrated row.
        try await store.updateAudiobookDownloadCurrentTime(id: "book-1", currentTime: 42)
        XCTAssertEqual(try store.audiobookDownload(forBook: "book-1")?.currentTime, 42)
    }

    // The single write funnel (AudioPlayerService.syncAudiobookProgress hooks
    // this once) that keeps AudiobookDownloadRecord.currentTime current for a
    // downloaded item regardless of whether the play was online or offline.
    // Fire-and-forget off the main actor (beads_mobilemusic-uxi kickback) — the
    // call returns a Task, so the test awaits `.value` to observe the write.
    @MainActor
    func testUpdateDownloadedCurrentTimeWritesToExistingRecord() async throws {
        let store = try makeInMemoryNavidromeStore()
        let manager = DownloadManager(store: store)
        let record = AudiobookDownloadRecord(
            id: "book-1", title: "T", status: .completed,
            files: [], chapters: [], createdAt: 0, updatedAt: 0
        )
        try store.upsert(audiobookDownload: record)

        await manager.updateDownloadedCurrentTime(itemID: "book-1", currentTime: 456).value

        let fetched = try store.audiobookDownload(forBook: "book-1")
        XCTAssertEqual(fetched?.currentTime, 456)
    }

    // No download record exists (the item was never downloaded) — the targeted
    // UPDATE must match zero rows: silent no-op, not a crash and not a
    // spuriously-created row (the guard now lives in the UPDATE's row-matching,
    // not a read-then-branch).
    @MainActor
    func testUpdateDownloadedCurrentTimeNoOpWhenNoRecordExists() async throws {
        let store = try makeInMemoryNavidromeStore()
        let manager = DownloadManager(store: store)

        await manager.updateDownloadedCurrentTime(itemID: "never-downloaded", currentTime: 100).value

        XCTAssertNil(try store.audiobookDownload(forBook: "never-downloaded"))
    }

    // Works for an episode's composite record id exactly like a book's plain id.
    @MainActor
    func testUpdateDownloadedCurrentTimeWritesToEpisodeRecord() async throws {
        let store = try makeInMemoryNavidromeStore()
        let manager = DownloadManager(store: store)
        let recordID = AudiobookDownloadRecord.episodeRecordID(showID: "show-1", episodeID: "ep-1")
        let record = AudiobookDownloadRecord(
            id: recordID, title: "Ep", status: .completed,
            files: [], chapters: [], createdAt: 0, updatedAt: 0
        )
        try store.upsert(audiobookDownload: record)

        await manager.updateDownloadedCurrentTime(itemID: recordID, currentTime: 789).value

        let fetched = try store.audiobookDownload(forBook: recordID)
        XCTAssertEqual(fetched?.currentTime, 789)
    }
}

// MARK: - E4 / 6b5.1: episode -> 1-file AudiobookDownloadRecord mapping

final class PodcastEpisodeDownloadTests: XCTestCase {

    private func episode(id: String, title: String = "Ep", duration: Double? = 1800, ino: String? = "ino-1") -> ABSEpisodeDTO {
        let audioFileJSON = ino.map { #"{"index":0,"ino":"\#($0)","duration":\#(duration.map { String($0) } ?? "null")}"# }
        let json = """
        {"id": "\(id)", "title": "\(title)", "duration": \(duration.map { String($0) } ?? "null"),
         "audioFile": \(audioFileJSON ?? "null")}
        """
        return try! JSONDecoder().decode(ABSEpisodeDTO.self, from: Data(json.utf8))
    }

    // Composite id round-trips and never collides with a plain book id.

    func testEpisodeRecordIDRoundTrips() {
        let id = AudiobookDownloadRecord.episodeRecordID(showID: "show-1", episodeID: "ep-1")
        let parsed = AudiobookDownloadRecord.parseEpisodeRecordID(id)
        XCTAssertEqual(parsed?.showID, "show-1")
        XCTAssertEqual(parsed?.episodeID, "ep-1")
    }

    func testPlainBookIDIsNotParsedAsEpisode() {
        XCTAssertNil(AudiobookDownloadRecord.parseEpisodeRecordID("li_abc"),
                     "a plain book libraryItemId must not be mistaken for an episode record id")
    }

    // The mapping: index=0, startOffset=0, chapters=[].

    func testForEpisodeMapsToSingleFileNoChapterRecord() {
        let ep = episode(id: "ep-1", title: "Episode One", duration: 1800, ino: "ino-42")
        let record = AudiobookDownloadRecord.forEpisode(
            showID: "show-1", showTitle: "The Show",
            episodeID: ep.id, episodeTitle: ep.title,
            coverPath: "/api/items/show-1/cover", audioFile: ep.audioFile
        )
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.id, "ep#show-1#ep-1")
        XCTAssertEqual(record?.title, "Episode One")
        XCTAssertEqual(record?.author, "The Show")
        XCTAssertEqual(record?.files.count, 1)
        XCTAssertEqual(record?.files.first?.index, 0)
        XCTAssertEqual(record?.files.first?.startOffset, 0)
        XCTAssertEqual(record?.files.first?.duration, 1800)
        XCTAssertEqual(record?.files.first?.ino, "ino-42")
        XCTAssertEqual(record?.chapters, [], "episodes carry no chapters")
        XCTAssertTrue(record!.isEpisodeDownload)
    }

    func testForEpisodeNilWhenNoAudioFile() {
        let ep = episode(id: "ep-2", ino: nil)
        let record = AudiobookDownloadRecord.forEpisode(
            showID: "show-1", showTitle: "The Show",
            episodeID: ep.id, episodeTitle: ep.title,
            coverPath: nil, audioFile: ep.audioFile
        )
        XCTAssertNil(record, "an episode with no downloadable audio file can't be downloaded")
    }

    func testBookRecordIsNotFlaggedAsEpisodeDownload() {
        let record = AudiobookDownloadRecord(
            id: "li_book1", title: "A Book", status: .completed,
            files: [], chapters: [], createdAt: 0, updatedAt: 0
        )
        XCTAssertFalse(record.isEpisodeDownload, "a book record's plain id must never be mistaken for an episode")
    }

    // timeline() rebuilds a single-file timeline from the mapped record —
    // exactly the same reconstruction offline audiobook playback uses.

    func testMappedEpisodeRecordRebuildsSingleFileTimeline() {
        let ep = episode(id: "ep-1", duration: 600, ino: "ino-9")
        var record = AudiobookDownloadRecord.forEpisode(
            showID: "show-1", showTitle: "Show",
            episodeID: ep.id, episodeTitle: ep.title,
            coverPath: nil, audioFile: ep.audioFile
        )!
        record.files[0].localPath = "/x/ep-1.audio"

        let tl = record.timeline()
        XCTAssertEqual(tl.files.count, 1)
        XCTAssertEqual(tl.totalDuration, 600)
        let located = tl.locate(global: 100)
        XCTAssertEqual(located?.file.index, 0)
        XCTAssertEqual(located?.fileOffset ?? -1, 100, accuracy: 0.001)
        XCTAssertEqual(located?.file.contentPath, "/x/ep-1.audio")
        XCTAssertNil(tl.chapter(at: 100), "episodes carry no chapters")
    }

    // MARK: Regression — server id vs record id (the two E4 download bugs)

    // BUG 1: the file-download URL must be built from the SERVER item id (the
    // SHOW id), never the "ep#..." record id, or the request 404s.
    func testServerItemIDForEpisodeIsTheShowNotTheRecordID() {
        let recordID = AudiobookDownloadRecord.episodeRecordID(showID: "li_show", episodeID: "ep-7")
        XCTAssertEqual(AudiobookDownloadRecord.serverItemID(forRecordID: recordID), "li_show")
    }

    func testServerItemIDForBookIsTheRecordIDUnchanged() {
        XCTAssertEqual(AudiobookDownloadRecord.serverItemID(forRecordID: "li_book"), "li_book")
    }
    // The URL-build + task-description round-trip regressions live in
    // AudiobookDownloadTests (testEpisodeFileDownloadURLUsesShowIDNotRecordID /
    // testEpisodeTaskDescriptionRoundTrips) next to the existing book cases.
}

// MARK: - E4 / 6b5.3: bulk "latest N" episode selection

final class PodcastBulkDownloadTests: XCTestCase {

    private func episodes(_ ids: [String]) -> [ABSEpisodeDTO] {
        let entries = ids.map { #"{"id": "\#($0)", "title": "Episode \#($0)"}"# }.joined(separator: ",")
        return try! JSONDecoder().decode([ABSEpisodeDTO].self, from: Data("[\(entries)]".utf8))
    }

    func testLatestNSelectsFirstNInGivenOrder() {
        let eps = episodes(["e1", "e2", "e3", "e4", "e5"])
        let latest3 = PodcastBulkDownload.latest(eps, count: 3)
        XCTAssertEqual(latest3.map(\.id), ["e1", "e2", "e3"])
    }

    func testLatestNClampsWhenCountExceedsListSize() {
        let eps = episodes(["e1", "e2"])
        let latest = PodcastBulkDownload.latest(eps, count: 5)
        XCTAssertEqual(latest.map(\.id), ["e1", "e2"], "N greater than the list just returns everything")
    }

    func testLatestZeroReturnsEmpty() {
        let eps = episodes(["e1", "e2"])
        XCTAssertTrue(PodcastBulkDownload.latest(eps, count: 0).isEmpty)
    }

    func testLatestOnEmptyListReturnsEmpty() {
        XCTAssertTrue(PodcastBulkDownload.latest([], count: 5).isEmpty)
    }

    func testDownloadAllIsJustTheFullList() {
        // "Download All" is `latest(episodes, count: episodes.count)` at the call
        // site — verify that degenerate case returns everything, in order.
        let eps = episodes(["e1", "e2", "e3"])
        XCTAssertEqual(PodcastBulkDownload.latest(eps, count: eps.count).map(\.id), ["e1", "e2", "e3"])
    }
}

// MARK: - E4 / 6b5.4: auto-delete-after-played decision

final class PodcastAutoDeleteTests: XCTestCase {

    func testDeletesWhenFinishedAndSettingOn() {
        XCTAssertTrue(AudioPlayerService.shouldAutoDeleteEpisode(finished: true, settingOn: true))
    }

    func testKeepsWhenSettingOffRegardlessOfFinished() {
        XCTAssertFalse(AudioPlayerService.shouldAutoDeleteEpisode(finished: true, settingOn: false))
        XCTAssertFalse(AudioPlayerService.shouldAutoDeleteEpisode(finished: false, settingOn: false))
    }

    func testKeepsWhenNotFinishedRegardlessOfSetting() {
        XCTAssertFalse(AudioPlayerService.shouldAutoDeleteEpisode(finished: false, settingOn: true))
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

    // pendingPosition must be episode-aware: two episodes of the same show
    // share `libraryItemId`, so a lookup for one must never return the
    // other's queued position (beads_mobilemusic-uxc kickback — offline
    // episode playback resumed at 0 because the lookup ignored episodeId).

    func testPendingPositionIsEpisodeAwareForSameShow() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("abs-queue-ep-pos-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let queue = ABSProgressSyncQueue(fileURL: tmp)
        await queue.enqueue(ABSProgressUpdate(libraryItemId: "show-1", episodeId: "ep-1", currentTime: 400, duration: 1800))
        await queue.enqueue(ABSProgressUpdate(libraryItemId: "show-1", episodeId: "ep-2", currentTime: 900, duration: 1800))

        let ep1 = await queue.pendingPosition(forBook: "show-1", episodeId: "ep-1")
        XCTAssertEqual(ep1, 400, "must resume the queried episode, not whichever one is queued")
        let ep2 = await queue.pendingPosition(forBook: "show-1", episodeId: "ep-2")
        XCTAssertEqual(ep2, 900)
        let ep3 = await queue.pendingPosition(forBook: "show-1", episodeId: "ep-3")
        XCTAssertNil(ep3, "a third episode of the same show has no queued progress")
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
