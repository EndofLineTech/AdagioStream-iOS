import CarPlay
import Foundation
import UIKit

// Podcast E5 / hky.1 — CarPlay podcast browsing + play.
//
// Mirrors CarPlayTemplateManager+Audiobooks.swift exactly: one root
// "Podcasts" entry that fetches lazily on tap, pushes a show list (or a
// library picker first when there's more than one podcast library), tapping
// a show pushes its episode list, and tapping an episode plays it via the
// shared AudioPlayerService.playPodcastEpisode path — CarPlay reimplements
// no playback. Whole-show auto-play is handled inside playPodcastEpisode's
// AudiobookSession(kind: .podcast(context:)), so no next/prev-track wiring is
// needed here (unlike audiobooks, where next/previous-track skips chapters —
// episodes have no chapters, and there's no other transport control that
// obviously means "next episode", so it's left unwired).
//
// Fetching reuses AudiobookshelfLibraryViewModel.loadPodcastShows/loadShowDetail,
// the same source of show/episode/cover data as iOS and tvOS.
extension CarPlayTemplateManager {

    /// Root "Podcasts" category item (fetches lazily on tap, like Audiobooks).
    func makePodcastsCategoryItem() -> CPListItem {
        let item = CPListItem(text: "Podcasts", detailText: "Browse your shows")
        item.accessoryType = .disclosureIndicator
        item.setImage(podcastPlaceholderImage())
        item.handler = { [weak self] _, completion in
            self?.pushPodcastShowList()
            completion()
        }
        return item
    }

    /// Pushes the show list, fetching via the shared library view-model. With
    /// more than one podcast library the top level becomes a library picker
    /// (mirrors the audiobook 6z5 behavior); a single library keeps the flat
    /// show list.
    func pushPodcastShowList() {
        log.log("Podcasts: pushPodcastShowList", category: .carplay)
        guard let api = providerManager.audiobookshelfAPI else { return }
        let loadingItem = CPListItem(text: "Loading…", detailText: nil)
        loadingItem.handler = { _, completion in completion() }
        let template = CPListTemplate(title: "Podcasts", sections: [CPListSection(items: [loadingItem])])
        interfaceController.pushTemplate(template, animated: true, completion: nil)

        let viewModel = AudiobookshelfLibraryViewModel(api: api)
        Task { @MainActor [weak self] in
            guard let self else { return }
            await viewModel.loadPodcastShows()
            switch viewModel.podcastShowsState {
            case .error(let message):
                template.updateSections([CPListSection(items: [self.emptyMusicItem(message)])])
            case .empty:
                template.updateSections([CPListSection(items: [self.emptyMusicItem("No podcasts")])])
            default:
                if viewModel.podcastLibraries.count > 1 {
                    let items = viewModel.podcastLibraries.map { library in
                        self.podcastLibraryPickerItem(library, viewModel: viewModel, api: api)
                    }
                    template.updateSections([CPListSection(items: items)])
                } else {
                    template.updateSections([self.showSection(viewModel.podcastShows, viewModel: viewModel, api: api)])
                }
            }
        }
    }

    /// One library row that drills into just that library's shows.
    private func podcastLibraryPickerItem(_ library: ABSLibraryDTO, viewModel: AudiobookshelfLibraryViewModel, api: AudiobookshelfAPI) -> CPListItem {
        let shows = viewModel.podcastShows.filter { $0.libraryId == library.id }
        let item = CPListItem(text: library.name, detailText: "\(shows.count) show\(shows.count == 1 ? "" : "s")")
        item.accessoryType = .disclosureIndicator
        item.setImage(podcastPlaceholderImage())
        item.handler = { [weak self] _, completion in
            guard let self else { completion(); return }
            let template = CPListTemplate(title: library.name, sections: [self.showSection(shows, viewModel: viewModel, api: api)])
            self.interfaceController.pushTemplate(template, animated: true, completion: nil)
            completion()
        }
        return item
    }

    /// A section of show rows (or an empty placeholder).
    private func showSection(_ shows: [PodcastShow], viewModel: AudiobookshelfLibraryViewModel, api: AudiobookshelfAPI) -> CPListSection {
        let items = shows.map { show in
            self.podcastShowRowItem(show, coverURL: viewModel.showCoverURLs[show.id], viewModel: viewModel, api: api)
        }
        return CPListSection(items: items.isEmpty ? [self.emptyMusicItem("No podcasts")] : items)
    }

    /// One show row: title + author, cover art, tap to drill into episodes.
    private func podcastShowRowItem(_ show: PodcastShow, coverURL: URL?, viewModel: AudiobookshelfLibraryViewModel, api: AudiobookshelfAPI) -> CPListItem {
        let item = CPListItem(text: show.title, detailText: show.author?.isEmpty == false ? show.author : nil)
        item.accessoryType = .disclosureIndicator
        item.handler = { [weak self] _, completion in
            self?.pushPodcastEpisodeList(show, viewModel: viewModel, api: api)
            completion()
        }
        if let coverURL {
            loadPodcastCover(url: coverURL, into: item)
        } else {
            item.setImage(podcastPlaceholderImage())
        }
        return item
    }

    /// Pushes one show's episode list, fetching via loadShowDetail.
    private func pushPodcastEpisodeList(_ show: PodcastShow, viewModel: AudiobookshelfLibraryViewModel, api: AudiobookshelfAPI) {
        log.log("Podcasts: pushPodcastEpisodeList \"\(show.title)\"", category: .carplay)
        let loadingItem = CPListItem(text: "Loading…", detailText: nil)
        loadingItem.handler = { _, completion in completion() }
        let template = CPListTemplate(title: show.title, sections: [CPListSection(items: [loadingItem])])
        interfaceController.pushTemplate(template, animated: true, completion: nil)

        Task { @MainActor [weak self] in
            guard let self else { return }
            await viewModel.loadShowDetail(show)
            switch viewModel.showDetailState {
            case .error(let message):
                template.updateSections([CPListSection(items: [self.emptyMusicItem(message)])])
            case .empty:
                template.updateSections([CPListSection(items: [self.emptyMusicItem("No episodes")])])
            default:
                // Server default order (newest-first) — matches PodcastPlaybackContext's
                // default and the ABS wire order; no in-CarPlay sort-order setting.
                let episodes = PodcastPlaybackContext.sortedEpisodes(viewModel.selectedShowEpisodes, order: .newestFirst)
                let context = PodcastPlaybackContext(libraryItemId: show.id, showTitle: show.title, episodes: episodes, order: .newestFirst)
                let items = episodes.map { episode in
                    self.podcastEpisodeRowItem(episode, show: show, context: context, api: api)
                }
                template.updateSections([CPListSection(items: items.isEmpty ? [self.emptyMusicItem("No episodes")] : items)])
            }
        }
    }

    /// One episode row: title + date/duration detail, tap-to-play with the
    /// show's full context so whole-show auto-play works.
    private func podcastEpisodeRowItem(_ episode: ABSEpisodeDTO, show: PodcastShow, context: PodcastPlaybackContext, api: AudiobookshelfAPI) -> CPListItem {
        let item = CPListItem(text: episode.title ?? "Episode", detailText: Self.podcastEpisodeRowDetail(episode))
        item.handler = { [weak self] _, completion in
            guard let self else { completion(); return }
            self.log.log("Podcasts: play \"\(episode.title ?? episode.id)\" from \"\(show.title)\"", category: .carplay)
            self.audioPlayer.playPodcastEpisode(episode, via: api, context: context, startGlobalTime: episode.userMediaProgress?.currentTime)
            self.pushNowPlaying()
            completion()
        }
        return item
    }

    /// Row detail text: publish date plus duration. Extracted static so the
    /// label logic is unit-testable without a live template manager.
    nonisolated static func podcastEpisodeRowDetail(_ episode: ABSEpisodeDTO) -> String? {
        let date = PodcastEpisodeRowView.formattedPubDate(episode.pubDate)
        let duration = episode.duration.map(AudiobookDetailView.formatDuration)
        switch (date, duration) {
        case let (date?, duration?): return "\(date) · \(duration)"
        case let (date?, nil): return date
        case let (nil, duration?): return duration
        case (nil, nil): return nil
        }
    }

    private func loadPodcastCover(url: URL, into item: CPListItem) {
        let size = CGSize(width: 40, height: 40)
        Task {
            guard let image = await ImageCacheService.shared.image(for: url) else { return }
            let renderer = UIGraphicsImageRenderer(size: size)
            let scaled = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            item.setImage(scaled)
        }
    }

    private func podcastPlaceholderImage() -> UIImage {
        let size = CGSize(width: 40, height: 40)
        let config = UIImage.SymbolConfiguration(pointSize: size.height * 0.8, weight: .medium)
        let symbol = UIImage(systemName: "mic", withConfiguration: config) ?? UIImage()
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in symbol.draw(in: CGRect(origin: .zero, size: size)) }
    }
}
