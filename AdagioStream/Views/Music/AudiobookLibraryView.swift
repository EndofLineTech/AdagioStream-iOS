// Audiobookshelf E2 / yu8.1 + yu8.4 — audiobook browsing UI.
//
// Blends into the existing Music library (PO decision: no separate tab). Mounted
// as an "Audiobooks" browse mode in MusicLibraryView. Book list → book detail
// (cover, author, progress, Resume/Play, chapter list). Chapter rows and the
// current-chapter highlight satisfy the yu8.4 chapter UI; skip controls live in
// the now-playing player, wired to AudioPlayerService.skipTo{Next,Previous}Chapter.
//
// iOS-only (tvOS parallel views are E4).

#if canImport(UIKit)
import SwiftUI

// MARK: - Book list

struct AudiobookBrowserView: View {
    @ObservedObject var viewModel: AudiobookshelfLibraryViewModel
    @EnvironmentObject private var audioPlayer: AudioPlayerService

    var body: some View {
        switch viewModel.booksState {
        case .idle, .loading:
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Loading audiobooks…").font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .empty:
            ScrollView {
                EmptyStateView(
                    title: "No Audiobooks",
                    systemImage: "books.vertical",
                    description: "Your Audiobookshelf server has no books, or none are in a book library."
                )
                .containerRelativeFrame([.horizontal, .vertical])
            }

        case .error(let message):
            ScrollView {
                VStack(spacing: 16) {
                    EmptyStateView(
                        title: "Couldn't Load Audiobooks",
                        systemImage: "exclamationmark.triangle",
                        description: message
                    )
                    Button {
                        Task { await viewModel.loadBooks() }
                    } label: { Label("Retry", systemImage: "arrow.clockwise") }
                    .buttonStyle(.bordered)
                }
                .containerRelativeFrame([.horizontal, .vertical])
            }

        case .loaded:
            List {
                if !viewModel.inProgress.isEmpty || !viewModel.inProgressEpisodes.isEmpty {
                    Section("Continue Listening") {
                        ContinueListeningShelf(viewModel: viewModel)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                    }
                }
                Section {
                    ForEach(viewModel.books, id: \.id) { book in
                        NavigationLink {
                            AudiobookDetailView(viewModel: viewModel, book: book)
                        } label: {
                            AudiobookRowView(book: book, coverURL: viewModel.coverURLs[book.id])
                        }
                        .accessibilityLabel(book.title)
                        .accessibilityHint("Open \(book.title)")
                    }
                }
            }
            .listStyle(.plain)
            .refreshable {
                await viewModel.loadBooks()
                await viewModel.loadInProgress()
            }
            .task { await viewModel.loadInProgress() }
        }
    }
}

// MARK: - Author browser (4xw.1)

/// The Books → Author sub-mode: the same books as `AudiobookBrowserView`,
/// grouped into sections by author (sorted), each book row unchanged. Pure
/// presentation over the existing view-model data — no new fetch.
struct AudiobookAuthorBrowserView: View {
    @ObservedObject var viewModel: AudiobookshelfLibraryViewModel

    /// Books grouped by author, each group sorted by title, groups sorted by
    /// author name (unknown author last).
    private var groups: [(author: String, books: [Audiobook])] {
        let byAuthor = Dictionary(grouping: viewModel.books) { book -> String in
            let a = book.author?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return a.isEmpty ? "Unknown Author" : a
        }
        return byAuthor
            .map { (author: $0.key, books: $0.value.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }) }
            .sorted { lhs, rhs in
                if lhs.author == "Unknown Author" { return false }
                if rhs.author == "Unknown Author" { return true }
                return lhs.author.localizedCaseInsensitiveCompare(rhs.author) == .orderedAscending
            }
    }

    var body: some View {
        switch viewModel.booksState {
        case .idle, .loading:
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Loading audiobooks…").font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .empty:
            ScrollView {
                EmptyStateView(
                    title: "No Audiobooks",
                    systemImage: "books.vertical",
                    description: "Your Audiobookshelf server has no books, or none are in a book library."
                )
                .containerRelativeFrame([.horizontal, .vertical])
            }

        case .error(let message):
            ScrollView {
                VStack(spacing: 16) {
                    EmptyStateView(title: "Couldn't Load Audiobooks", systemImage: "exclamationmark.triangle", description: message)
                    Button { Task { await viewModel.loadBooks() } } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
                .containerRelativeFrame([.horizontal, .vertical])
            }

        case .loaded:
            List {
                ForEach(groups, id: \.author) { group in
                    Section(group.author) {
                        ForEach(group.books, id: \.id) { book in
                            NavigationLink {
                                AudiobookDetailView(viewModel: viewModel, book: book)
                            } label: {
                                AudiobookRowView(book: book, coverURL: viewModel.coverURLs[book.id])
                            }
                            .accessibilityLabel(book.title)
                            .accessibilityHint("Open \(book.title)")
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await viewModel.loadBooks() }
        }
    }
}

// MARK: - Continue Listening shelf (00t; podcast episodes mixed in E3 / c2s.3)

/// Horizontal shelf of in-progress books AND podcast episodes (c2s.3 — one
/// shelf, not a separate row per the PO decision). Books resume via
/// `playAudiobook`; episodes resume via `playPodcastEpisode` with a
/// single-episode `PodcastPlaybackContext` (same rationale as the Recent
/// Episodes tap — see `PodcastRecentEpisodesView.recentEpisodesContext`:
/// whole-show auto-play from a resume tap isn't in scope here, only resuming
/// the specific episode is).
private struct ContinueListeningShelf: View {
    @ObservedObject var viewModel: AudiobookshelfLibraryViewModel
    @EnvironmentObject private var audioPlayer: AudioPlayerService
    @EnvironmentObject private var settingsViewModel: SettingsViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(viewModel.inProgress, id: \.id) { book in
                    Button {
                        audioPlayer.playAudiobook(book, via: viewModel.audiobookshelfAPI)
                    } label: {
                        ContinueListeningCard(title: book.title, coverURL: viewModel.coverURLs[book.id], progress: book.progress, placeholderIcon: "book.closed")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Resume \(book.title)")
                }
                ForEach(viewModel.inProgressEpisodes) { entry in
                    Button {
                        let order = settingsViewModel.settings.podcastEpisodeSortOrder.podcastEpisodeOrder
                        let context = PodcastPlaybackContext(
                            libraryItemId: entry.showLibraryItemId,
                            showTitle: entry.showTitle,
                            episodes: [entry.episode],
                            order: order
                        )
                        audioPlayer.playPodcastEpisode(entry.episode, via: viewModel.audiobookshelfAPI, context: context)
                    } label: {
                        ContinueListeningCard(
                            title: entry.episode.title ?? "Episode",
                            coverURL: viewModel.showCoverURLs[entry.showLibraryItemId],
                            progress: entry.progress,
                            placeholderIcon: "mic"
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Resume \(entry.episode.title ?? "episode")")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}

private struct ContinueListeningCard: View {
    let title: String
    let coverURL: URL?
    let progress: Double
    var placeholderIcon: String = "book.closed"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            cover
            Text(title).font(.caption).foregroundStyle(.primary).lineLimit(2)
            ProgressView(value: min(1, progress))
                .progressViewStyle(.linear)
                .tint(.accentColor)
        }
        .frame(width: 120)
    }

    @ViewBuilder private var cover: some View {
        if let coverURL {
            RetryableAsyncImage(url: coverURL, width: 120, height: 120, cornerRadius: 8, persistent: true)
                .accessibilityHidden(true)
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.secondarySystemBackground))
                .frame(width: 120, height: 120)
                .overlay(Image(systemName: placeholderIcon).foregroundStyle(.secondary))
        }
    }
}

// MARK: - Book row

struct AudiobookRowView: View {
    let book: Audiobook
    let coverURL: URL?

    var body: some View {
        HStack(spacing: 12) {
            cover
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title).font(.body).foregroundStyle(.primary).lineLimit(2)
                if let author = book.author, !author.isEmpty {
                    Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if book.progress > 0 && !book.isFinished {
                    ProgressView(value: min(1, book.progress))
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                        .padding(.top, 2)
                } else if book.isFinished {
                    Label("Finished", systemImage: "checkmark.circle.fill")
                        .font(.caption2).foregroundStyle(.green)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var cover: some View {
        if let coverURL {
            RetryableAsyncImage(url: coverURL, width: 44, height: 44, cornerRadius: 6, persistent: true)
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(.secondarySystemBackground))
                .frame(width: 44, height: 44)
                .overlay(Image(systemName: "book.closed").foregroundStyle(.secondary))
        }
    }
}

// MARK: - Book detail

struct AudiobookDetailView: View {
    @ObservedObject var viewModel: AudiobookshelfLibraryViewModel
    let book: Audiobook
    @EnvironmentObject private var audioPlayer: AudioPlayerService
    @EnvironmentObject private var downloadManager: DownloadManager

    /// The live record (progress refreshed by loadDetail), falling back to the
    /// list record.
    private var current: Audiobook { viewModel.selectedBook ?? book }

    var body: some View {
        List {
            Section {
                header
            }
            Section("Chapters") {
                if viewModel.chapters.isEmpty {
                    Text(viewModel.detailState == .loading ? "Loading chapters…" : "No chapters.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.chapters, id: \.id) { chapter in
                        chapterRow(chapter)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(current.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.loadDetail(for: book) }
        .onDisappear { viewModel.resetDetail() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            if let url = viewModel.coverURLs[book.id] {
                RetryableAsyncImage(url: url, width: 96, height: 96, cornerRadius: 8, persistent: true)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(current.title).font(.headline).lineLimit(3)
                if let author = current.author, !author.isEmpty {
                    Text(author).font(.subheadline).foregroundStyle(.secondary)
                }
                if let duration = current.duration {
                    Text(Self.formatDuration(duration)).font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    startPlayback()
                } label: {
                    Label(resumeLabel, systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
                .accessibilityLabel(resumeLabel)

                downloadControl
            }
        }
        .padding(.vertical, 4)
    }

    /// Download / downloading / delete affordance (E3). Shown only when the user
    /// has download permission (or a download already exists on this device).
    @ViewBuilder private var downloadControl: some View {
        let record = downloadManager.audiobookDownloads.first { $0.id == current.id }
        if viewModel.canDownload || record != nil {
            switch record?.status {
            case .completed:
                Button(role: .destructive) {
                    downloadManager.deleteBookDownload(itemID: current.id)
                } label: {
                    Label("Remove Download", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Remove download")
            case .downloading, .queued:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Downloading…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            case .failed:
                Button {
                    Task { await viewModel.downloadBook(current, using: downloadManager) }
                } label: {
                    Label("Retry Download", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Retry download")
            default:
                Button {
                    Task { await viewModel.downloadBook(current, using: downloadManager) }
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Download for offline listening")
            }
        }
    }

    private var resumeLabel: String {
        current.progress > 0 && !current.isFinished ? "Resume" : "Play"
    }

    /// Resumes from the server position (`playAudiobook` seeds from /play, so no
    /// explicit start time is needed for the normal Resume/Play button).
    private func startPlayback(from global: Double? = nil) {
        audioPlayer.playAudiobook(current, via: viewModel.audiobookshelfAPI, startGlobalTime: global)
    }

    @ViewBuilder
    private func chapterRow(_ chapter: AudiobookChapter) -> some View {
        let isCurrent = audioPlayer.currentAudiobook?.id == current.id
            && audioPlayer.currentChapter?.id == chapter.id
        Button {
            startPlayback(from: chapter.start)
        } label: {
            HStack {
                Image(systemName: isCurrent ? "play.circle.fill" : "circle")
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
                Text(chapter.title).foregroundStyle(.primary).lineLimit(2)
                Spacer()
                // Show the chapter's LENGTH (end - start), not its start offset
                // (bug 4xw.4 — the row previously displayed the start timestamp).
                Text(Self.formatTimestamp(chapter.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(chapter.title)
        .accessibilityHint("Play from \(Self.formatTimestamp(chapter.start)), \(Self.formatTimestamp(chapter.duration)) long")
    }

    // MARK: - Formatting

    static func formatTimestamp(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    static func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        let h = s / 3600, m = (s % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}
#endif // canImport(UIKit)
