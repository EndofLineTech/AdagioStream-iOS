import CarPlay
import Foundation
import UIKit

// Audiobookshelf E4 / ciu.1 — CarPlay audiobook browsing + resume.
//
// Mirrors the Navidrome-music browse path (makeMusicCategoryItems + push*List):
// one root "Audiobooks" entry that fetches lazily on tap and pushes a book list.
// Tapping a book resumes playback via the shared AudioPlayerService+Audiobook
// path (server or local position) — CarPlay reimplements no playback. Chapter
// skip is handled by the shared next/previous-track remote commands, which route
// to skipTo{Next,Previous}Chapter while an audiobook is current.
//
// Fetching reuses AudiobookshelfLibraryViewModel.loadBooks so there's a single
// source of book/cover data across iOS, tvOS, and CarPlay.
extension CarPlayTemplateManager {

    /// Root "Audiobooks" category item (fetches lazily on tap, like the music
    /// categories). Resolves the ABS API at tap time so it survives provider
    /// changes; an empty/failed fetch shows a placeholder rather than hiding.
    func makeAudiobooksCategoryItem() -> CPListItem {
        let item = CPListItem(text: "Audiobooks", detailText: "Browse your library")
        item.accessoryType = .disclosureIndicator
        item.setImage(audiobookPlaceholderImage())
        item.handler = { [weak self] _, completion in
            self?.pushAudiobookList()
            completion()
        }
        return item
    }

    /// Pushes the book list, fetching via the shared library view-model.
    func pushAudiobookList() {
        log.log("Audiobooks: pushAudiobookList", category: .carplay)
        guard let api = providerManager.audiobookshelfAPI else { return }
        let loadingItem = CPListItem(text: "Loading…", detailText: nil)
        loadingItem.handler = { _, completion in completion() }
        let template = CPListTemplate(title: "Audiobooks", sections: [CPListSection(items: [loadingItem])])
        interfaceController.pushTemplate(template, animated: true, completion: nil)

        let viewModel = AudiobookshelfLibraryViewModel(api: api)
        Task { @MainActor [weak self] in
            guard let self else { return }
            await viewModel.loadBooks()
            switch viewModel.booksState {
            case .error(let message):
                template.updateSections([CPListSection(items: [self.emptyMusicItem(message)])])
            case .empty:
                template.updateSections([CPListSection(items: [self.emptyMusicItem("No audiobooks")])])
            default:
                let items = viewModel.books.map { book in
                    self.audiobookRowItem(book, coverURL: viewModel.coverURLs[book.id], api: api)
                }
                template.updateSections([CPListSection(items: items.isEmpty
                    ? [self.emptyMusicItem("No audiobooks")]
                    : items)])
            }
        }
    }

    /// One book row: title + author/progress detail, cover art, tap-to-resume.
    private func audiobookRowItem(_ book: Audiobook, coverURL: URL?, api: AudiobookshelfAPI) -> CPListItem {
        let item = CPListItem(text: book.title, detailText: Self.audiobookRowDetail(book))
        item.handler = { [weak self] _, completion in
            guard let self else { completion(); return }
            self.log.log("Audiobooks: play \"\(book.title)\" (resume)", category: .carplay)
            // Resumes from server/local position — playAudiobook seeds the start.
            self.audioPlayer.playAudiobook(book, via: api)
            self.pushNowPlaying()
            completion()
        }
        if let coverURL {
            loadAudiobookCover(url: coverURL, into: item)
        } else {
            item.setImage(audiobookPlaceholderImage())
        }
        return item
    }

    /// Row detail text: author plus a progress hint. Extracted static so the
    /// label logic is unit-testable without a live template manager.
    nonisolated static func audiobookRowDetail(_ book: Audiobook) -> String? {
        let author = (book.author?.isEmpty == false) ? book.author : nil
        let status: String?
        if book.isFinished {
            status = "Finished"
        } else if book.progress > 0 {
            status = "\(Int((min(1, book.progress) * 100).rounded()))% listened"
        } else {
            status = nil
        }
        switch (author, status) {
        case let (author?, status?): return "\(author) · \(status)"
        case let (author?, nil): return author
        case let (nil, status?): return status
        case (nil, nil): return nil
        }
    }

    private func loadAudiobookCover(url: URL, into item: CPListItem) {
        let size = CGSize(width: 40, height: 40)
        Task {
            guard let image = await ImageCacheService.shared.image(for: url) else { return }
            let renderer = UIGraphicsImageRenderer(size: size)
            let scaled = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            item.setImage(scaled)
        }
    }

    private func audiobookPlaceholderImage() -> UIImage {
        let size = CGSize(width: 40, height: 40)
        let config = UIImage.SymbolConfiguration(pointSize: size.height * 0.8, weight: .medium)
        let symbol = UIImage(systemName: "book.closed", withConfiguration: config) ?? UIImage()
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in symbol.draw(in: CGRect(origin: .zero, size: size)) }
    }
}
