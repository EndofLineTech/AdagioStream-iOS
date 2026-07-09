import XCTest
@testable import AdagioStream

// Audiobookshelf E2 / yu8.2 — the global↔file timeline math is the core of
// audiobook playback (multi-file chaining on one continuous timeline). These
// are the smallest checks that fail if that math breaks.

final class AudiobookTimelineTests: XCTestCase {

    // A 3-file book: [0,1000), [1000,2500), [2500,3600). Total 3600s.
    private func makeTimeline() -> AudiobookTimeline {
        AudiobookTimeline(
            files: [
                .init(index: 0, startOffset: 0,    duration: 1000, contentPath: "/f0"),
                .init(index: 1, startOffset: 1000, duration: 1500, contentPath: "/f1"),
                .init(index: 2, startOffset: 2500, duration: 1100, contentPath: "/f2"),
            ],
            chapters: [
                .init(id: "b#0", bookId: "b", title: "One",   start: 0,    end: 1200),
                .init(id: "b#1", bookId: "b", title: "Two",   start: 1200, end: 2500),
                .init(id: "b#2", bookId: "b", title: "Three", start: 2500, end: 3600),
            ]
        )
    }

    func testTotalDuration() {
        XCTAssertEqual(makeTimeline().totalDuration, 3600, accuracy: 0.001)
    }

    func testLocateWithinFirstFile() {
        let (file, offset) = makeTimeline().locate(global: 500)!
        XCTAssertEqual(file.index, 0)
        XCTAssertEqual(offset, 500, accuracy: 0.001)
    }

    func testLocateInMiddleFileSubtractsStartOffset() {
        // Global 1600 is 600s into file 1 (which starts at 1000).
        let (file, offset) = makeTimeline().locate(global: 1600)!
        XCTAssertEqual(file.index, 1)
        XCTAssertEqual(offset, 600, accuracy: 0.001)
    }

    func testLocateAtFileBoundaryPicksNextFile() {
        // Exactly at 1000 belongs to file 1 (ranges are [start, end)).
        let (file, offset) = makeTimeline().locate(global: 1000)!
        XCTAssertEqual(file.index, 1)
        XCTAssertEqual(offset, 0, accuracy: 0.001)
    }

    func testLocateClampsPastEndToLastFile() {
        let (file, _) = makeTimeline().locate(global: 9999)!
        XCTAssertEqual(file.index, 2)
    }

    func testLocateClampsNegativeToStart() {
        let (file, offset) = makeTimeline().locate(global: -50)!
        XCTAssertEqual(file.index, 0)
        XCTAssertEqual(offset, 0, accuracy: 0.001)
    }

    func testGlobalTimeMapsPerFilePositionBack() {
        let tl = makeTimeline()
        let file = tl.files[1]
        // 300s into file 1 → global 1300.
        XCTAssertEqual(tl.globalTime(file: file, fileOffset: 300), 1300, accuracy: 0.001)
    }

    func testFileAfterChains() {
        let tl = makeTimeline()
        XCTAssertEqual(tl.fileAfter(tl.files[0])?.index, 1)
        XCTAssertEqual(tl.fileAfter(tl.files[1])?.index, 2)
        XCTAssertNil(tl.fileAfter(tl.files[2]), "last file has no successor")
    }

    func testUnsortedFilesAreSortedByStartOffset() {
        let tl = AudiobookTimeline(files: [
            .init(index: 2, startOffset: 2500, duration: 1100, contentPath: "/f2"),
            .init(index: 0, startOffset: 0,    duration: 1000, contentPath: "/f0"),
            .init(index: 1, startOffset: 1000, duration: 1500, contentPath: "/f1"),
        ])
        XCTAssertEqual(tl.files.map(\.index), [0, 1, 2])
    }

    func testEmptyTimelineLocateReturnsNil() {
        XCTAssertNil(AudiobookTimeline(files: []).locate(global: 100))
    }

    // MARK: - Chapters (yu8.4)

    func testChapterAtGlobalTime() {
        let tl = makeTimeline()
        XCTAssertEqual(tl.chapter(at: 100)?.title, "One")
        XCTAssertEqual(tl.chapter(at: 1200)?.title, "Two")  // boundary → next
        XCTAssertEqual(tl.chapter(at: 3000)?.title, "Three")
    }

    func testChapterSpansFileBoundary() {
        // Chapter "One" (0–1200) spans the file0/file1 boundary at 1000, and
        // "Two" (1200–2500) ends exactly at the file1/file2 boundary — proves
        // chapters are on the global timeline, not per-file.
        let tl = makeTimeline()
        XCTAssertEqual(tl.chapter(at: 950)?.title, "One")   // file 0
        XCTAssertEqual(tl.chapter(at: 1050)?.title, "One")  // file 1, same chapter
        XCTAssertEqual(tl.chapter(at: 2400)?.title, "Two")  // file 1
        XCTAssertEqual(tl.chapter(at: 2600)?.title, "Three") // file 2
    }

    func testNextChapterStart() {
        let tl = makeTimeline()
        XCTAssertEqual(tl.nextChapterStart(after: 100), 1200 as Double)
        XCTAssertEqual(tl.nextChapterStart(after: 1300), 2500 as Double)
        XCTAssertNil(tl.nextChapterStart(after: 3000), "no chapter after the last")
    }

    func testPreviousChapterRestartsCurrentWhenDeepIn() {
        let tl = makeTimeline()
        // 100s into "Two" (starts 1200) → restart "Two".
        XCTAssertEqual(tl.previousChapterStart(from: 1300), 1200 as Double)
    }

    func testPreviousChapterJumpsBackWhenNearStart() {
        let tl = makeTimeline()
        // 2s into "Two" → jump to "One".
        XCTAssertEqual(tl.previousChapterStart(from: 1202), 0 as Double)
    }

    // MARK: - Session → timeline

    func testTimelineBuildsFromSessionDTO() throws {
        let json = """
        {
          "id": "sess-1",
          "playMethod": 0,
          "currentTime": 1350.0,
          "duration": 3600.0,
          "chapters": [ { "id": 0, "title": "Intro", "start": 0, "end": 1200 } ],
          "audioTracks": [
            { "index": 0, "startOffset": 0,    "duration": 1000, "title": "f0", "mimeType": "audio/mp4", "contentUrl": "/s/item/li_x/0.m4b" },
            { "index": 1, "startOffset": 1000, "duration": 2600, "title": "f1", "mimeType": "audio/mp4", "contentUrl": "/s/item/li_x/1.m4b" }
          ]
        }
        """
        let dto = try JSONDecoder().decode(ABSPlaybackSessionDTO.self, from: Data(json.utf8))
        let tl = AudiobookTimeline(session: dto, bookId: "li_x")

        XCTAssertEqual(dto.playMethod, 0)
        XCTAssertEqual(try XCTUnwrap(dto.currentTime), 1350, accuracy: 0.001)
        XCTAssertEqual(tl.files.count, 2)
        XCTAssertEqual(tl.files[1].contentPath, "/s/item/li_x/1.m4b")
        XCTAssertEqual(tl.totalDuration, 3600, accuracy: 0.001)
        // Resume at 1350 lands 350s into file 1.
        let (file, offset) = tl.locate(global: dto.currentTime!)!
        XCTAssertEqual(file.index, 1)
        XCTAssertEqual(offset, 350, accuracy: 0.001)
        XCTAssertEqual(tl.chapters.first?.id, "li_x#0")
    }
}
