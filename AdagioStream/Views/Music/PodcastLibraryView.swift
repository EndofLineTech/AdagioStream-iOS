// Audiobookshelf E3 / c2s.1, c2s.2 — podcast browsing UI.
//
// Blends into the existing Music library the same way Books does (PO
// decision carried over from E2/yu8.1): mounted as a "Podcasts" section in
// MusicLibraryView, with a By Show | Recent Episodes sub-mode in the nav-bar
// Menu (c2s.1). Show grid -> show's episode list -> episode detail/play.
//
// iOS-only (tvOS parallel views are a later epic, E5).

#if canImport(UIKit)
import SwiftUI

// MARK: - By Show: show grid

struct PodcastShowGridView: View {
    @ObservedObject var viewModel: AudiobookshelfLibraryViewModel

    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 16)]

    var body: some View {
        LoadableContent(
            state: viewModel.podcastShowsState,
            loadingText: "Loading podcasts…",
            emptyTitle: "No Podcasts",
            emptySystemImage: "mic",
            emptyDescription: "Your Audiobookshelf server has no shows, or none are in a podcast library.",
            errorTitle: "Couldn't Load Podcasts",
            retry: { Task { await viewModel.loadPodcastShows() } }
        ) {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(viewModel.podcastShows) { show in
                        NavigationLink {
                            PodcastEpisodeListView(viewModel: viewModel, show: show)
                        } label: {
                            PodcastShowTile(show: show, coverURL: viewModel.showCoverURLs[show.id])
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(show.title)
                        .accessibilityHint("Open \(show.title) episodes")
                    }
                }
                .padding(16)
            }
            .refreshable { await viewModel.loadPodcastShows() }
        }
    }
}

private struct PodcastShowTile: View {
    let show: PodcastShow
    let coverURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            cover
            Text(show.title).font(.subheadline).foregroundStyle(.primary).lineLimit(2)
            if let author = show.author, !author.isEmpty {
                Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    @ViewBuilder private var cover: some View {
        if let coverURL {
            RetryableAsyncImage(url: coverURL, width: 140, height: 140, cornerRadius: 8, persistent: true)
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.secondarySystemBackground))
                .frame(width: 140, height: 140)
                .overlay(Image(systemName: "mic").foregroundStyle(.secondary))
        }
    }
}

// MARK: - Show's episode list

struct PodcastEpisodeListView: View {
    @ObservedObject var viewModel: AudiobookshelfLibraryViewModel
    let show: PodcastShow
    @EnvironmentObject private var settingsViewModel: SettingsViewModel
    @EnvironmentObject private var downloadManager: DownloadManager
    @EnvironmentObject private var providerManager: ProviderManager

    private var order: PodcastEpisodeOrder { settingsViewModel.settings.podcastEpisodeSortOrder.podcastEpisodeOrder }

    private var sortedEpisodes: [ABSEpisodeDTO] {
        PodcastPlaybackContext.sortedEpisodes(viewModel.selectedShowEpisodes, order: order)
    }

    private var context: PodcastPlaybackContext {
        PodcastPlaybackContext(
            libraryItemId: show.id,
            showTitle: show.title,
            episodes: viewModel.selectedShowEpisodes,
            order: order
        )
    }

    var body: some View {
        LoadableContent(
            state: viewModel.showDetailState,
            loadingText: "Loading episodes…",
            emptyTitle: "No Episodes",
            emptySystemImage: "mic",
            emptyDescription: "This show has no episodes.",
            errorTitle: "Couldn't Load Episodes",
            retry: { Task { await viewModel.loadShowDetail(show) } }
        ) {
            List(sortedEpisodes, id: \.id) { episode in
                NavigationLink {
                    PodcastEpisodeDetailView(episode: episode, show: show, context: context)
                } label: {
                    HStack {
                        PodcastEpisodeRowView(episode: episode)
                        Spacer(minLength: 8)
                        EpisodeDownloadButton(show: show, episode: episode, compact: true)
                    }
                }
                .accessibilityLabel(episode.title ?? "Episode")
            }
            .listStyle(.plain)
            .refreshable { await viewModel.loadShowDetail(show) }
        }
        .navigationTitle(show.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if !sortedEpisodes.isEmpty {
                    Menu {
                        Button {
                            bulkDownload(episodes: sortedEpisodes)
                        } label: {
                            Label("Download All", systemImage: "arrow.down.circle")
                        }
                        Button {
                            bulkDownload(episodes: PodcastBulkDownload.latest(sortedEpisodes, count: 5))
                        } label: {
                            Label("Download Latest 5", systemImage: "arrow.down.circle")
                        }
                    } label: {
                        Image(systemName: "arrow.down.circle")
                    }
                    .accessibilityLabel("Download episodes")
                }
            }
        }
        .task { await viewModel.loadShowDetail(show) }
        .onDisappear { viewModel.resetShowDetail() }
    }

    private func bulkDownload(episodes: [ABSEpisodeDTO]) {
        guard let api = providerManager.audiobookshelfAPI else { return }
        for episode in episodes {
            AudiobookshelfLibraryViewModel.downloadEpisode(episode, show: show, using: downloadManager, via: api)
        }
    }
}

// MARK: - Bulk download selection (E4 / 6b5.3)

/// Pure "which episodes does a bulk action download" selection, so it's
/// unit-testable without the view/DownloadManager. `episodes` is expected
/// already sorted in the order "latest" means (caller passes
/// `PodcastPlaybackContext.sortedEpisodes(..., order: .newestFirst)`-derived
/// order — whatever order the episode list is currently showing).
enum PodcastBulkDownload {
    /// The first `count` episodes of an already-ordered list. Clamps to the
    /// list's size; `count <= 0` or an empty list returns `[]`.
    static func latest(_ episodes: [ABSEpisodeDTO], count: Int) -> [ABSEpisodeDTO] {
        guard count > 0, !episodes.isEmpty else { return [] }
        return Array(episodes.prefix(count))
    }
}

// MARK: - Recent Episodes: flat list across the podcast library

struct PodcastRecentEpisodesView: View {
    @ObservedObject var viewModel: AudiobookshelfLibraryViewModel
    @EnvironmentObject private var settingsViewModel: SettingsViewModel

    private var order: PodcastEpisodeOrder { settingsViewModel.settings.podcastEpisodeSortOrder.podcastEpisodeOrder }

    var body: some View {
        LoadableContent(
            state: viewModel.recentEpisodesState,
            loadingText: "Loading recent episodes…",
            emptyTitle: "No Episodes",
            emptySystemImage: "mic",
            emptyDescription: "Your podcast library has no episodes yet.",
            errorTitle: "Couldn't Load Episodes",
            retry: { Task { await viewModel.loadRecentEpisodes(order: order) } }
        ) {
            List(viewModel.recentEpisodes) { entry in
                NavigationLink {
                    PodcastEpisodeDetailView(
                        episode: entry.episode,
                        show: PodcastShow(id: entry.showLibraryItemId, libraryId: "", title: entry.showTitle ?? "Podcast", author: nil),
                        context: recentEpisodesContext(for: entry)
                    )
                } label: {
                    PodcastEpisodeRowView(episode: entry.episode, showTitle: entry.showTitle)
                }
                .accessibilityLabel(entry.episode.title ?? "Episode")
            }
            .listStyle(.plain)
            .refreshable { await viewModel.loadRecentEpisodes(order: order) }
        }
        .task { await viewModel.loadRecentEpisodes(order: order) }
    }

    /// A single-episode playback context for a Recent-Episodes tap: whole-show
    /// auto-play still needs the show's full episode list, but Recent Episodes
    /// only carries the flattened entries. Falling back to a one-episode
    /// context (no auto-play beyond this episode) keeps the tap-to-play path
    /// working without an extra show-detail fetch on every row.
    /// ponytail: single-episode context here; upgrade to fetch the full show
    /// episode list on tap only if auto-play-from-Recent-Episodes is requested.
    private func recentEpisodesContext(for entry: PodcastEpisodeEntry) -> PodcastPlaybackContext {
        PodcastPlaybackContext(
            libraryItemId: entry.showLibraryItemId,
            showTitle: entry.showTitle,
            episodes: [entry.episode],
            order: order
        )
    }
}

// MARK: - Episode row

struct PodcastEpisodeRowView: View {
    let episode: ABSEpisodeDTO
    var showTitle: String? = nil

    private var entry: PodcastEpisodeEntry {
        PodcastEpisodeEntry(episode: episode, showLibraryItemId: "", showTitle: showTitle)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if entry.isUnplayed {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
                    .padding(.top, 6)
                    .accessibilityHidden(true)
            } else {
                Circle().fill(Color.clear).frame(width: 8, height: 8).padding(.top, 6)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(episode.title ?? "Episode").font(.body).foregroundStyle(.primary).lineLimit(2)
                if let showTitle, !showTitle.isEmpty {
                    Text(showTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 6) {
                    if let dateText = PodcastEpisodeRowView.formattedPubDate(episode.pubDate) {
                        Text(dateText)
                    }
                    if let duration = episode.duration {
                        if episode.pubDate != nil { Text("·") }
                        Text(AudiobookDetailView.formatDuration(duration))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if entry.progress > 0 && !entry.isFinished {
                    ProgressView(value: min(1, entry.progress))
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                        .padding(.top, 2)
                } else if entry.isFinished {
                    Label("Played", systemImage: "checkmark.circle.fill")
                        .font(.caption2).foregroundStyle(.green)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// Localized display date for an episode's `pubDate`. Parses via the shared
    /// `PodcastPlaybackContext.parsePubDate` (same RFC-2822 parser the sort
    /// uses), then formats medium/no-time. `nil` (shows nothing) rather than
    /// mangled text when the format doesn't match.
    static func formattedPubDate(_ pubDate: String?) -> String? {
        guard let date = PodcastPlaybackContext.parsePubDate(pubDate) else { return nil }
        let display = DateFormatter()
        display.dateStyle = .medium
        display.timeStyle = .none
        return display.string(from: date)
    }
}

// MARK: - Episode detail

struct PodcastEpisodeDetailView: View {
    let episode: ABSEpisodeDTO
    let show: PodcastShow
    /// The show's full playback context (its whole episode list, in the
    /// current sort order) so tapping Play drives whole-show auto-play
    /// (c2s.2/c2s.4) via `playPodcastEpisode`.
    let context: PodcastPlaybackContext
    @EnvironmentObject private var audioPlayer: AudioPlayerService
    @EnvironmentObject private var providerManager: ProviderManager

    private var entry: PodcastEpisodeEntry {
        PodcastEpisodeEntry(episode: episode, showLibraryItemId: show.id, showTitle: show.title)
    }

    // Episode summary/show-notes isn't modeled on ABSEpisodeDTO (E1/E2 scope
    // only decoded title/duration/pubDate/audioFile/progress) — the header
    // below is the full detail surface available.
    var body: some View {
        List {
            Section {
                header
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(episode.title ?? "Episode")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(episode.title ?? "Episode").font(.headline).lineLimit(4)
            Text(show.title).font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                if let dateText = PodcastEpisodeRowView.formattedPubDate(episode.pubDate) {
                    Text(dateText)
                }
                if let duration = episode.duration {
                    if episode.pubDate != nil { Text("·") }
                    Text(AudiobookDetailView.formatDuration(duration))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Button {
                guard let api = providerManager.audiobookshelfAPI else { return }
                audioPlayer.playPodcastEpisode(episode, via: api, context: context)
            } label: {
                Label(resumeLabel, systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(providerManager.audiobookshelfAPI == nil)
            .accessibilityLabel(resumeLabel)

            EpisodeDownloadButton(show: show, episode: episode, compact: false)
        }
        .padding(.vertical, 4)
    }

    private var resumeLabel: String {
        entry.progress > 0 && !entry.isFinished ? "Resume" : "Play"
    }
}

// MARK: - Episode download control (E4 / 6b5.1)

/// Download / downloading / delete affordance for one episode — same
/// visual language + status switch as `AudiobookLibraryView.downloadControl`,
/// just compacted to an icon-only control when used on a list row (`compact`).
struct EpisodeDownloadButton: View {
    let show: PodcastShow
    let episode: ABSEpisodeDTO
    var compact: Bool

    @EnvironmentObject private var downloadManager: DownloadManager
    @EnvironmentObject private var providerManager: ProviderManager

    private var record: AudiobookDownloadRecord? {
        downloadManager.audiobookDownloads.first {
            $0.id == AudiobookDownloadRecord.episodeRecordID(showID: show.id, episodeID: episode.id)
        }
    }

    var body: some View {
        switch record?.status {
        case .completed:
            button(systemImage: "checkmark.circle.fill", tint: .green, label: "Remove Download") {
                downloadManager.deleteEpisodeDownload(showID: show.id, episodeID: episode.id)
            }
        case .downloading, .queued:
            if compact {
                ProgressView().controlSize(.mini)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Downloading…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        case .failed:
            button(systemImage: "arrow.clockwise", tint: .red, label: "Retry Download", startDownload)
        default:
            button(systemImage: "arrow.down.circle", tint: .accentColor, label: "Download Episode", startDownload)
        }
    }

    private func startDownload() {
        guard let api = providerManager.audiobookshelfAPI else { return }
        AudiobookshelfLibraryViewModel.downloadEpisode(episode, show: show, using: downloadManager, via: api)
    }

    @ViewBuilder
    private func button(systemImage: String, tint: Color, label: String, _ action: @escaping () -> Void) -> some View {
        if compact {
            // uxd.2: 44pt hit area to match TrackDownloadButton — the glyph
            // itself stays compact via .body, only the tappable frame grows.
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.body)
                    .foregroundStyle(tint)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
        } else {
            Button(role: label == "Remove Download" ? .destructive : nil, action: action) {
                Label(label, systemImage: systemImage)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(label)
        }
    }
}

#endif // canImport(UIKit)
