import XCTest
@testable import AdagioStream

// Covers the DTO→record transform, focusing on global-timeline chapter decoding
// (start/end span file boundaries) and per-user progress mapping.

final class AudiobookshelfModelsTests: XCTestCase {

    // A minified item-detail payload with 3 chapters whose start/end are on a
    // single GLOBAL timeline (chapter 2 starts where chapter 1 ends, etc.).
    private let itemJSON = """
    {
      "id": "item-1",
      "libraryId": "lib-1",
      "media": {
        "duration": 3600.0,
        "metadata": { "title": "The Long Book", "authorName": "Jane Doe" },
        "chapters": [
          { "id": 0, "title": "Intro",   "start": 0.0,    "end": 1200.0 },
          { "id": 1, "title": "Middle",  "start": 1200.0, "end": 2500.0 },
          { "id": 2, "title": "End",     "start": 2500.0, "end": 3600.0 }
        ]
      },
      "userMediaProgress": {
        "currentTime": 1350.5, "progress": 0.375, "isFinished": false, "lastUpdate": 1720000000000
      }
    }
    """

    func testItemDecodesToAudiobookRecord() throws {
        let dto = try JSONDecoder().decode(ABSLibraryItemDTO.self, from: Data(itemJSON.utf8))
        let book = dto.toRecord(libraryIdFallback: "fallback", updatedAt: 42)

        XCTAssertEqual(book.id, "item-1")
        XCTAssertEqual(book.libraryId, "lib-1")
        XCTAssertEqual(book.title, "The Long Book")
        XCTAssertEqual(book.author, "Jane Doe")
        XCTAssertEqual(book.duration, 3600.0)
        XCTAssertEqual(book.coverPath, "/api/items/item-1/cover")
        XCTAssertEqual(book.currentTime, 1350.5, accuracy: 0.001)
        XCTAssertEqual(book.progress, 0.375, accuracy: 0.001)
        XCTAssertFalse(book.isFinished)
        XCTAssertEqual(book.lastUpdate, 1720000000000)
        XCTAssertEqual(book.updatedAt, 42)
    }

    func testChaptersUseGlobalTimeline() throws {
        let dto = try JSONDecoder().decode(ABSLibraryItemDTO.self, from: Data(itemJSON.utf8))
        let chapters = dto.chapters()

        XCTAssertEqual(chapters.count, 3)
        // start/end are the raw global-timeline values — no per-file re-basing.
        XCTAssertEqual(chapters[0].start, 0.0)
        XCTAssertEqual(chapters[0].end, 1200.0)
        XCTAssertEqual(chapters[1].start, 1200.0)  // continues where ch0 ended
        XCTAssertEqual(chapters[2].end, 3600.0)    // spans to the book's full duration

        // Chapters are contiguous on one timeline: each start == prior end.
        for i in 1..<chapters.count {
            XCTAssertEqual(chapters[i].start, chapters[i - 1].end, accuracy: 0.001,
                           "global timeline must be contiguous across file boundaries")
        }

        // IDs are namespaced by book so they stay unique table-wide.
        XCTAssertEqual(chapters[0].id, "item-1#0")
        XCTAssertEqual(chapters[1].bookId, "item-1")
    }

    func testLibraryFilterKeepsBooksOnly() throws {
        let json = """
        {"libraries":[
          {"id":"a","name":"Books","mediaType":"book"},
          {"id":"b","name":"Pods","mediaType":"podcast"}
        ]}
        """
        let response = try JSONDecoder().decode(ABSLibrariesResponse.self, from: Data(json.utf8))
        let books = response.libraries.filter(\.isBook)
        XCTAssertEqual(books.map(\.id), ["a"])
    }

    // MARK: - yha.2: podcast library filtering

    func testLibraryFilterKeepsPodcastsOnly() throws {
        let json = """
        {"libraries":[
          {"id":"a","name":"Books","mediaType":"book"},
          {"id":"b","name":"Pods","mediaType":"podcast"}
        ]}
        """
        let response = try JSONDecoder().decode(ABSLibrariesResponse.self, from: Data(json.utf8))
        let pods = response.libraries.filter(\.isPodcast)
        XCTAssertEqual(pods.map(\.id), ["b"])
        XCTAssertFalse(response.libraries[1].isBook)
        XCTAssertFalse(response.libraries[0].isPodcast)
    }

    // MARK: - yha.3: podcast show + episode decoding

    // A podcast show library item with 2 episodes (expanded shape — episodes[]
    // populated, mirroring how audioFiles[] only appears on the expanded shape).
    private let podcastShowJSON = """
    {
      "id": "show-1",
      "libraryId": "lib-pods",
      "media": {
        "metadata": { "title": "The Daily Byte", "author": "Byte Media" },
        "episodes": [
          {
            "id": "ep-1",
            "title": "Episode One",
            "duration": 1800.0,
            "pubDate": "2026-07-01",
            "audioFile": { "index": 0, "ino": "111", "duration": 1800.0 },
            "userMediaProgress": { "currentTime": 900.0, "progress": 0.5, "isFinished": false, "lastUpdate": 1720000000000 }
          },
          {
            "id": "ep-2",
            "title": "Episode Two",
            "duration": 2400.0,
            "pubDate": "2026-07-08",
            "audioFile": { "index": 0, "ino": "222", "duration": 2400.0 }
          }
        ]
      }
    }
    """

    func testPodcastShowDecodesShowTitleAndAuthor() throws {
        let dto = try JSONDecoder().decode(ABSLibraryItemDTO.self, from: Data(podcastShowJSON.utf8))
        XCTAssertEqual(dto.showTitle, "The Daily Byte")
        XCTAssertEqual(dto.media?.metadata?.displayAuthor, "Byte Media")
    }

    func testPodcastEpisodesDecodeFromShow() throws {
        let dto = try JSONDecoder().decode(ABSLibraryItemDTO.self, from: Data(podcastShowJSON.utf8))
        let episodes = dto.episodes()

        XCTAssertEqual(episodes.count, 2)
        XCTAssertEqual(episodes[0].id, "ep-1")
        XCTAssertEqual(episodes[0].title, "Episode One")
        XCTAssertEqual(episodes[0].duration, 1800.0)
        XCTAssertEqual(episodes[0].audioFile?.ino, "111")
        XCTAssertEqual(episodes[0].userMediaProgress?.currentTime, 900.0)

        // Second episode has no progress payload — decodes to nil, not a crash.
        XCTAssertNil(episodes[1].userMediaProgress)
        XCTAssertEqual(episodes[1].audioFile?.ino, "222")
    }

    func testBookMetadataAuthorNameStillWinsOverAuthor() throws {
        // Books only ever send authorName; displayAuthor must keep returning it.
        let dto = try JSONDecoder().decode(ABSLibraryItemDTO.self, from: Data(itemJSON.utf8))
        XCTAssertEqual(dto.media?.metadata?.displayAuthor, "Jane Doe")
    }
}
