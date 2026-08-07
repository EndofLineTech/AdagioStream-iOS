import XCTest
@testable import AdagioStream

// Audiobookshelf E2 / yu8.3 — progress-sync payload + resume-position logic.
// The smallest checks that fail if the resume precedence or timeListened delta
// break. (Network sync/close is exercised only against a live server.)

@MainActor
final class AudiobookSyncTests: XCTestCase {

    // MARK: - Resume precedence

    func testResumePrefersExplicitOverride() {
        let r = AudioPlayerService.resumePosition(override: 900, sessionCurrentTime: 500, bookCurrentTime: 100)
        XCTAssertEqual(r, 900, accuracy: 0.001)
    }

    func testResumeFallsBackToSessionCurrentTime() {
        let r = AudioPlayerService.resumePosition(override: nil, sessionCurrentTime: 500, bookCurrentTime: 100)
        XCTAssertEqual(r, 500, accuracy: 0.001, "server /play currentTime is the resume point")
    }

    func testResumeFallsBackToBookRecordWhenServerNil() {
        let r = AudioPlayerService.resumePosition(override: nil, sessionCurrentTime: nil, bookCurrentTime: 100)
        XCTAssertEqual(r, 100, accuracy: 0.001)
    }

    func testResumeZeroFromScratch() {
        let r = AudioPlayerService.resumePosition(override: nil, sessionCurrentTime: nil, bookCurrentTime: 0)
        XCTAssertEqual(r, 0, accuracy: 0.001)
    }

    // MARK: - timeListened delta

    func testTimeListenedIsForwardDelta() {
        XCTAssertEqual(AudioPlayerService.timeListened(sinceLastSynced: 100, currentGlobal: 120), 20, accuracy: 0.001)
    }

    func testTimeListenedClampsBackwardSeekToZero() {
        // Seeking backward must never report negative listen time.
        XCTAssertEqual(AudioPlayerService.timeListened(sinceLastSynced: 200, currentGlobal: 150), 0, accuracy: 0.001)
    }

    func testTimeListenedZeroWhenNoProgress() {
        XCTAssertEqual(AudioPlayerService.timeListened(sinceLastSynced: 300, currentGlobal: 300), 0, accuracy: 0.001)
    }

    // MARK: - Offline-max resume seeding (ymf.6)

    func testMaxIgnoringNilPrefersLarger() {
        // Offline reached 800; server /play resumes at an older 500 → keep 800.
        XCTAssertEqual(AudioPlayerService.maxIgnoringNil(800, 500), 800)
    }

    func testMaxIgnoringNilFallsThroughNil() {
        XCTAssertEqual(AudioPlayerService.maxIgnoringNil(nil, 500), 500)
        XCTAssertEqual(AudioPlayerService.maxIgnoringNil(800, nil), 800)
        XCTAssertNil(AudioPlayerService.maxIgnoringNil(nil, nil))
    }

    func testResumeUsesOfflineMaxOverOlderServerPosition() {
        // The offline-max is passed as sessionCurrentTime; a reconnecting live
        // session that resumed older must not rewind past it.
        let seeded = AudioPlayerService.maxIgnoringNil(800, 500)
        let r = AudioPlayerService.resumePosition(override: nil, sessionCurrentTime: seeded, bookCurrentTime: 100)
        XCTAssertEqual(r, 800, accuracy: 0.001)
    }

    // MARK: - Offline episode resume (beads_mobilemusic-uxc kickback)
    //
    // Mirrors the exact derivation `playDownloadedEpisode` performs: a
    // manifest-reconstructed `ABSEpisodeDTO` (built by the offline browser
    // with no network fetch) carries `userMediaProgress == nil`, so
    // `bookCurrentTime` is always 0 — the offline progress queue, looked up
    // via the episode-aware `pendingPosition(forBook:episodeId:)`, is the only
    // reachable source of a resume position. Uses a disposable on-disk queue
    // (same pattern as `ABSProgressSyncQueueTests`) — deterministic, no
    // network, no mocked VLC/session machinery.

    func testReconstructedEpisodeResumesFromMatchingQueueEntry() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("abs-queue-resume-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let queue = ABSProgressSyncQueue(fileURL: tmp)
        await queue.enqueue(ABSProgressUpdate(libraryItemId: "show-1", episodeId: "ep-1", currentTime: 640, duration: 1800))

        let offlinePending = await queue.pendingPosition(forBook: "show-1", episodeId: "ep-1")
        let resume = AudioPlayerService.resumePosition(override: nil, sessionCurrentTime: offlinePending, bookCurrentTime: 0)
        XCTAssertEqual(resume, 640, accuracy: 0.001, "reconstructed episode + matching queue entry resumes there")
    }

    func testReconstructedEpisodeIgnoresADifferentEpisodesQueuedProgress() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("abs-queue-resume-collision-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let queue = ABSProgressSyncQueue(fileURL: tmp)
        // Only a DIFFERENT episode of the same show has queued progress.
        await queue.enqueue(ABSProgressUpdate(libraryItemId: "show-1", episodeId: "ep-2", currentTime: 900, duration: 1800))

        let offlinePending = await queue.pendingPosition(forBook: "show-1", episodeId: "ep-1")
        let resume = AudioPlayerService.resumePosition(override: nil, sessionCurrentTime: offlinePending, bookCurrentTime: 0)
        XCTAssertEqual(resume, 0, accuracy: 0.001, "must not pick up a different episode's queued progress")
    }

    func testReconstructedEpisodeResumesAtZeroWithNoProgressAnywhere() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("abs-queue-resume-empty-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let queue = ABSProgressSyncQueue(fileURL: tmp)

        let offlinePending = await queue.pendingPosition(forBook: "show-1", episodeId: "ep-1")
        let resume = AudioPlayerService.resumePosition(override: nil, sessionCurrentTime: offlinePending, bookCurrentTime: 0)
        XCTAssertEqual(resume, 0, accuracy: 0.001)
    }

    // MARK: - Offline resume precedence with the local download record (uxi)
    //
    // playDownloadedAudiobook/playDownloadedEpisode now seed `sessionCurrentTime`
    // as `maxIgnoringNil(queuePosition, record.currentTime)` — the same
    // `maxIgnoringNil` idiom ymf.6 already uses for queue-vs-server, applied to
    // queue-vs-local-record so an item last played ONLINE (record has a
    // position, queue is empty) still resumes correctly offline. Full
    // precedence: explicit override > max(queue, record) > userMediaProgress > 0.

    func testOfflineResumePrefersExplicitOverrideOverQueueAndRecord() {
        let seeded = AudioPlayerService.maxIgnoringNil(300, 700)
        let r = AudioPlayerService.resumePosition(override: 999, sessionCurrentTime: seeded, bookCurrentTime: 50)
        XCTAssertEqual(r, 999, accuracy: 0.001)
    }

    func testOfflineResumeRecordNewerThanQueue() {
        // Last play was online (record has 900), an OLDER offline queue entry
        // (300) is still pending flush — the record must win.
        let seeded = AudioPlayerService.maxIgnoringNil(300, 900)
        let r = AudioPlayerService.resumePosition(override: nil, sessionCurrentTime: seeded, bookCurrentTime: 50)
        XCTAssertEqual(r, 900, accuracy: 0.001, "the local record's newer online-play position must not be rewound by a stale queue entry")
    }

    func testOfflineResumeQueueNewerThanRecord() {
        // A fresh offline session (queue 950) hasn't flushed to the record yet
        // (record still at the last online position, 400) — the queue must win.
        let seeded = AudioPlayerService.maxIgnoringNil(950, 400)
        let r = AudioPlayerService.resumePosition(override: nil, sessionCurrentTime: seeded, bookCurrentTime: 50)
        XCTAssertEqual(r, 950, accuracy: 0.001)
    }

    func testOfflineResumeFallsBackToUserMediaProgressWhenNeitherQueueNorRecordExist() {
        let seeded = AudioPlayerService.maxIgnoringNil(nil, nil)
        let r = AudioPlayerService.resumePosition(override: nil, sessionCurrentTime: seeded, bookCurrentTime: 50)
        XCTAssertEqual(r, 50, accuracy: 0.001, "no queue and no record (e.g. never played) falls back to userMediaProgress")
    }

    func testOfflineResumeUsesRecordAloneWhenQueueEmpty() {
        // The exact online-only-played scenario this bead closes: no queue
        // entry exists (last play was online), only the local record has a
        // position.
        let seeded = AudioPlayerService.maxIgnoringNil(nil, 640)
        let r = AudioPlayerService.resumePosition(override: nil, sessionCurrentTime: seeded, bookCurrentTime: 0)
        XCTAssertEqual(r, 640, accuracy: 0.001)
    }
}
