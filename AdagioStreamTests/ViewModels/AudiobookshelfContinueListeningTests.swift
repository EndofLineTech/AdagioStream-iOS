import XCTest
@testable import AdagioStream

// 00t — Continue-Listening filter: keep started, not-finished books in server
// order; drop finished and unstarted ones.
@MainActor
final class AudiobookshelfContinueListeningTests: XCTestCase {

    private func item(id: String, progress: Double, finished: Bool) -> ABSLibraryItemDTO {
        let json = """
        {
          "id": "\(id)",
          "libraryId": "lib-1",
          "media": { "duration": 100.0, "metadata": { "title": "\(id)" } },
          "userMediaProgress": { "currentTime": 10.0, "progress": \(progress), "isFinished": \(finished) }
        }
        """
        return try! JSONDecoder().decode(ABSLibraryItemDTO.self, from: Data(json.utf8))
    }

    func testKeepsStartedUnfinishedInServerOrder() {
        let items = [
            item(id: "started-a", progress: 0.4, finished: false),
            item(id: "finished", progress: 1.0, finished: true),
            item(id: "unstarted", progress: 0.0, finished: false),
            item(id: "started-b", progress: 0.1, finished: false),
        ]
        let result = AudiobookshelfLibraryViewModel.inProgressBooks(from: items, updatedAt: 1)
        XCTAssertEqual(result.map(\.id), ["started-a", "started-b"])
    }

    func testEmptyWhenNothingInProgress() {
        let items = [item(id: "finished", progress: 1.0, finished: true)]
        XCTAssertTrue(AudiobookshelfLibraryViewModel.inProgressBooks(from: items, updatedAt: 1).isEmpty)
    }
}
