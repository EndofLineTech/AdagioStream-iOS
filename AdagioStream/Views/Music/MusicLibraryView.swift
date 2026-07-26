// 0xy.3 — Navidrome browse UI: root artists list
// 0xy.4 — Extended with album-browse and genre-browse modes via a segmented Picker.
// l31.3 — Offline mode: when offlineMode is on, restrict to downloaded tracks only.
//
// MusicLibraryView is the NavigationStack root for the "Music" tab (mounted by
// 0xy.5).  It resolves the NavidromeAPI from ProviderManager.shared.subsonicAPI
// on first appear and builds the NavidromeLibraryViewModel from it.
//
// Self-contained NavigationStack — does NOT expect to be embedded in one.
//
// Browse modes (nav-bar trailing Menu, 3h6.6):
//   • Artists  — artist list → ArtistDetailView → AlbumDetailView (0xy.3)
//   • Albums   — BrowseAlbumsView with a type picker (newest/recent/frequent/random/A–Z)
//   • Genres   — GenreListView → GenreDetailView (0xy.4)
//
// Offline mode (l31.3):
//   When AppSettings.offlineMode is true, the normal browse modes are replaced
//   by a downloaded-tracks list.  No network browse/search calls are made.
//   A banner at the top explains the restriction.

#if canImport(UIKit)
import SwiftUI

// MARK: - Browse mode

/// Music sub-modes (shown when the top-level section is Music). The former
/// `.audiobooks` case is gone — books are now their own top-level section
/// (4xw.1) with their own sub-modes below.
enum MusicBrowseMode: String, CaseIterable {
    case artists   = "Artists"
    case albums    = "Albums"
    case genres    = "Genres"
    case playlists = "Playlists"
}

/// Top-level library section: Books vs Podcasts vs Music (4xw.1; Podcasts
/// added E3 / c2s.1). Offered only when the corresponding provider/content
/// actually exists.
enum LibrarySection: String, CaseIterable {
    case books = "Books"
    case podcasts = "Podcasts"
    case music = "Music"
}

/// Book sub-modes (shown when the top-level section is Books). `titles` is the
/// existing flat book list; `author` groups the same books by author (4xw.1).
enum BookBrowseMode: String, CaseIterable {
    case author = "Author"
    case titles = "Titles"
}

/// Podcast sub-modes (shown when the top-level section is Podcasts, E3 / c2s.1).
enum PodcastBrowseMode: String, CaseIterable {
    case byShow = "By Show"
    case recentEpisodes = "Recent Episodes"
}

// MARK: - MusicLibraryView

public struct MusicLibraryView: View {

    @EnvironmentObject private var providerManager: ProviderManager
    @EnvironmentObject private var downloadManager: DownloadManager
    @EnvironmentObject private var audioPlayer: AudioPlayerService
    @EnvironmentObject private var settingsViewModel: SettingsViewModel

    // State for the resolved API.  Resolved once in .task so that the entire
    // NavigationStack shares a single API instance (and therefore a single cache
    // salt set) for the lifetime of this view.
    @State private var api: NavidromeAPI?

    // The view-model is created lazily once we have a valid API.
    @State private var viewModel: NavidromeLibraryViewModel?

    // Audiobookshelf (E2 / yu8.1): resolved API + view-model, when an ABS
    // provider is configured. Independent of the Subsonic API above — either
    // provider can exist without the other.
    @State private var absAPI: AudiobookshelfAPI?
    @State private var absViewModel: AudiobookshelfLibraryViewModel?

    // Top-level section (Books | Podcasts | Music) and per-section sub-mode.
    // All persist across tab switches (4xw.1; Podcasts added c2s.1).
    @State private var section: LibrarySection = .music
    @State private var browseMode: MusicBrowseMode = .artists
    @State private var bookMode: BookBrowseMode = .titles
    @State private var podcastMode: PodcastBrowseMode = .byShow

    // Search query text — bound to the .searchable modifier.
    // Non-empty → show SearchResultsView; empty → show normal browse.
    @State private var searchText: String = ""

    // Track titles for the offline downloaded list (l31.3).
    @State private var offlineTrackTitles: [String: String] = [:]

    // Presents the add-account flow from the "no library" empty state (3h6.11).
    @State private var showAddProvider = false

    public init() {}

    public var body: some View {
        NavigationStack {
            // The section switch renders as an inline header pinned above the
            // content (b42) — NOT in the nav-bar .principal, where stacked
            // pills overflowed into the status bar / Dynamic Island and over the
            // large title. VStack(spacing: 0) keeps the header inside the safe
            // area below the nav bar; the content sits beneath it. The per-section
            // sub-mode picker lives in the nav-bar trailing Menu instead (3h6.6),
            // so this header is just the single Books|Music row now.
            VStack(spacing: 0) {
                // Hide the selector header in offline mode and while searching.
                if !settingsViewModel.settings.offlineMode && !isSearchActive {
                    browseModeSelector
                }
                content
            }
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Sub-mode picker (Apple Music / Books pattern) — replaces the
                // second segmented-control row that used to stack under the
                // Books|Music switch (3h6.6). Hidden in offline mode and while
                // searching, matching the Books|Music header above.
                if !settingsViewModel.settings.offlineMode && !isSearchActive {
                    ToolbarItem(placement: .topBarTrailing) {
                        subModeMenu
                    }
                }
            }
            .searchableIfMusic(
                isMusic: showsSearch,
                text: $searchText,
                prompt: section == .books ? "Search title or author" : "Search artists, albums, songs"
            )
            .accessibilityLabel(section == .books ? "Search audiobooks" : "Search music library")
            // Podcasts (c2s.1) has no search wiring yet — see the note in
            // `content`'s podcasts branch.
            .onChange(of: searchText) { _, newValue in
                // Books search filters client-side in the browser views below;
                // only Music drives the Subsonic server search here.
                guard section == .music, !settingsViewModel.settings.offlineMode else { return }
                viewModel?.updateSearch(query: newValue)
            }
            .task {
                // Resolve the Audiobookshelf provider (yu8.1) independently of
                // Subsonic — either can exist alone. No offline gate: ABS
                // browsing needs the network.
                if absViewModel == nil, let absResolved = providerManager.audiobookshelfAPI {
                    absAPI = absResolved
                    let absVM = AudiobookshelfLibraryViewModel(api: absResolved)
                    absViewModel = absVM
                    await absVM.loadBooks()
                    // Podcasts (c2s.1): loaded alongside books so
                    // `hasPodcastLibrary` is known before the section switch
                    // first renders — gates whether Podcasts is offered at all.
                    await absVM.loadPodcastShows()
                }

                guard let resolved = providerManager.subsonicAPI else {
                    // ABS-only: land on the Books section (preserves the prior
                    // ABS-only auto-land behaviour, 4xw.1).
                    if absViewModel != nil { section = .books }
                    return
                }
                // Both providers, or Subsonic-only: default to Music.
                section = .music
                if api == nil {
                    api = resolved
                    let vm = NavidromeLibraryViewModel(api: resolved)
                    viewModel = vm
                    // Skip network load when offline mode is on at startup.
                    if !settingsViewModel.settings.offlineMode {
                        await vm.loadArtists()
                    }
                }
            }
            .sheet(isPresented: $showAddProvider) {
                AddProviderView()
                    .presentationDetents([.medium, .large])
            }
        }
    }

    /// The mode-specific content beneath the selector header.
    @ViewBuilder
    private var content: some View {
        if settingsViewModel.settings.offlineMode {
            // Offline mode: show downloaded tracks only, suppress network calls.
            offlineBrowser
        } else if section == .books, let absVM = absViewModel {
            // Books section (4xw.1): Titles = flat list, Author = grouped.
            if isSearchActive {
                BookSearchResultsView(viewModel: absVM, query: searchText)
            } else {
                switch bookMode {
                case .titles: AudiobookBrowserView(viewModel: absVM)
                case .author: AudiobookAuthorBrowserView(viewModel: absVM)
                }
            }
        } else if section == .podcasts, let absVM = absViewModel {
            // Podcasts section (c2s.1/c2s.2): By Show = grid -> episode list;
            // Recent Episodes = flat list across the whole podcast library.
            // No search wiring yet (c2s.1 scope is the selector + browse UI).
            switch podcastMode {
            case .byShow: PodcastShowGridView(viewModel: absVM)
            case .recentEpisodes: PodcastRecentEpisodesView(viewModel: absVM)
            }
        } else if let vm = viewModel, let resolvedAPI = api {
            // Show search results when there is a non-empty query;
            // otherwise show the normal browse UI unchanged.
            if isSearchActive {
                SearchResultsView(viewModel: vm, api: resolvedAPI)
            } else {
                libraryBrowser(vm: vm, api: resolvedAPI)
            }
        } else if providerManager.subsonicAPI == nil && absViewModel == nil {
            ScrollView {
                EmptyStateView(
                    title: "No Music Library",
                    systemImage: "music.note.house",
                    description: "Add a Navidrome/Subsonic or Audiobookshelf account in Settings → Accounts.",
                    actionLabel: "Add Account"
                ) {
                    showAddProvider = true
                }
                .containerRelativeFrame([.horizontal, .vertical])
            }
        } else if providerManager.subsonicAPI == nil, let absVM = absViewModel {
            // ABS-only: default straight into the audiobooks browser
            // (the .task lands `section` on .books, this covers the
            // first render before that runs).
            if isSearchActive {
                BookSearchResultsView(viewModel: absVM, query: searchText)
            } else {
                switch bookMode {
                case .titles: AudiobookBrowserView(viewModel: absVM)
                case .author: AudiobookAuthorBrowserView(viewModel: absVM)
                }
            }
        } else {
            ProgressView("Loading library…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Search applies in both sections (3h6.9): Music does a server search via
    /// the view-model, Books filters the already-loaded list client-side.
    /// Hidden in offline mode (b42) — no network browse/search there.
    private var showsSearch: Bool {
        !settingsViewModel.settings.offlineMode && section != .podcasts
    }

    /// True when the search field has non-empty (non-whitespace) text.
    private var isSearchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Mode selector (4xw.1 — two levels)

    /// Top-level sections actually available: Music when a Subsonic provider is
    /// configured, Books when an ABS provider is, Podcasts when the ABS
    /// provider additionally has at least one podcast library (c2s.1) — mirrors
    /// how Books is gated on the ABS provider existing at all. `hasPodcastLibrary`
    /// reflects the last `loadPodcastShows()` call in MusicLibraryView's `.task`.
    private var availableSections: [LibrarySection] {
        var s: [LibrarySection] = []
        if absViewModel != nil { s.append(.books) }
        if absViewModel?.hasPodcastLibrary == true { s.append(.podcasts) }
        if providerManager.subsonicAPI != nil { s.append(.music) }
        return s
    }

    /// Section switch, rendered as an inline header pinned above the content
    /// (b42): picks Books|Music (only shown when both exist — a single
    /// available section needs no switch). The per-section sub-mode picker
    /// lives in the nav-bar trailing menu instead (3h6.6, see `subModeMenu`).
    @ViewBuilder
    private var browseModeSelector: some View {
        if availableSections.count > 1 {
            Picker("Section", selection: $section) {
                ForEach(availableSections, id: \.self) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 300)
            .accessibilityLabel("Library section")
            .accessibilityHint("Switch between Books and Music")
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity)
            .background(Color(.systemBackground))
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    /// Nav-bar trailing sub-mode picker (3h6.6) — the Apple Music / Books
    /// pattern: a Menu button showing the active sub-mode for whichever
    /// section is current, replacing the second segmented-control row that
    /// used to stack under the Books|Music switch. Provider-gating doesn't
    /// apply here — sub-modes are always the full case set for the active
    /// section (only whether a section is offered at all is gated, in
    /// `availableSections`).
    @ViewBuilder
    private var subModeMenu: some View {
        switch section {
        case .music:
            Menu {
                Picker("Browse", selection: $browseMode) {
                    ForEach(MusicBrowseMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
            } label: {
                Label(browseMode.rawValue, systemImage: "chevron.up.chevron.down")
                    .labelStyle(.titleAndIcon)
            }
            .accessibilityLabel("Music browse mode")
            .accessibilityHint("Switch between Artists, Albums, Genres, and Playlists")
        case .books:
            Menu {
                Picker("Books", selection: $bookMode) {
                    ForEach(BookBrowseMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
            } label: {
                Label(bookMode.rawValue, systemImage: "chevron.up.chevron.down")
                    .labelStyle(.titleAndIcon)
            }
            .accessibilityLabel("Book browse mode")
            .accessibilityHint("Switch between Author and Titles")
        case .podcasts:
            Menu {
                Picker("Podcasts", selection: $podcastMode) {
                    ForEach(PodcastBrowseMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
            } label: {
                Label(podcastMode.rawValue, systemImage: "chevron.up.chevron.down")
                    .labelStyle(.titleAndIcon)
            }
            .accessibilityLabel("Podcast browse mode")
            .accessibilityHint("Switch between By Show and Recent Episodes")
        }
    }

    // MARK: - Offline browser (l31.3, unioned with ABS downloads uxc.1)

    /// Downloaded audiobooks (excludes podcast episodes, which are namespaced
    /// `ep#<showID>#<episodeID>` — see `AudiobookDownloadRecord.isEpisodeDownload`).
    private var offlineBooks: [AudiobookDownloadRecord] {
        downloadManager.audiobookDownloads.filter { $0.status == .completed && !$0.isEpisodeDownload }
    }

    /// Downloaded podcast episodes.
    private var offlineEpisodes: [AudiobookDownloadRecord] {
        downloadManager.audiobookDownloads.filter { $0.status == .completed && $0.isEpisodeDownload }
    }

    /// Shown when offline mode is on. Lists downloaded tracks, audiobooks, and
    /// podcast episodes across all providers (uxc.1) — no network calls made.
    @ViewBuilder
    private var offlineBrowser: some View {
        let downloads = downloadManager.downloads.filter { $0.status == .completed }
        let books = offlineBooks
        let episodes = offlineEpisodes

        VStack(spacing: 0) {
            // Offline mode banner
            HStack(spacing: 8) {
                Image(systemName: "wifi.slash")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Offline mode — showing downloaded content")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemBackground))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Offline mode — showing downloaded content only")

            if downloads.isEmpty && books.isEmpty && episodes.isEmpty {
                ScrollView {
                    EmptyStateView(
                        title: "No Downloads",
                        systemImage: "arrow.down.circle",
                        description: "No downloaded content available. Turn off offline mode or download music, audiobooks, or episodes first."
                    )
                    .containerRelativeFrame([.horizontal, .vertical])
                }
            } else {
                List {
                    if !downloads.isEmpty {
                        Section("Music") {
                            ForEach(downloads, id: \.id) { record in
                                OfflineTrackRow(
                                    record: record,
                                    title: offlineTrackTitles[record.id],
                                    onPlay: {
                                        playOfflineDownloads(startingAt: record.id, downloads: downloads)
                                    }
                                )
                            }
                        }
                    }
                    if !books.isEmpty {
                        Section("Audiobooks") {
                            ForEach(books, id: \.id) { record in
                                OfflineDownloadRow(
                                    title: record.title,
                                    subtitle: record.author,
                                    systemImage: "books.vertical.fill",
                                    onPlay: { playOfflineBook(record) }
                                )
                            }
                        }
                    }
                    if !episodes.isEmpty {
                        Section("Podcast Episodes") {
                            ForEach(episodes, id: \.id) { record in
                                OfflineDownloadRow(
                                    title: record.title,
                                    subtitle: record.author,
                                    systemImage: "mic.fill",
                                    onPlay: { playOfflineEpisode(record) }
                                )
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .task {
            resolveOfflineTrackTitles(downloads: downloads)
        }
        .onChange(of: downloadManager.downloads) { _, newDownloads in
            let completed = newDownloads.filter { $0.status == .completed }
            resolveOfflineTrackTitles(downloads: completed)
        }
    }

    /// Plays a downloaded audiobook offline. Reuses `AudioPlayerService
    /// .playAudiobook`'s existing offline routing (E3 / mkj.2) — offline mode
    /// is guaranteed on here, so it resolves straight to the local-file path.
    /// Resume position: best-effort from the cached `Audiobook` row if the book
    /// was ever browsed online; otherwise starts from 0.
    private func playOfflineBook(_ record: AudiobookDownloadRecord) {
        guard let absAPI else { return }
        let cached = try? NavidromeStore.shared.writer.read { db in try Audiobook.fetchOne(db, key: record.id) }
        let book = cached ?? Audiobook(
            id: record.id,
            libraryItemId: record.id,
            libraryId: "",
            title: record.title,
            author: record.author,
            duration: record.duration,
            updatedAt: record.updatedAt
        )
        audioPlayer.playAudiobook(book, via: absAPI)
    }

    /// Plays a downloaded podcast episode offline, reconstructing the minimal
    /// `ABSEpisodeDTO`/`PodcastPlaybackContext` the offline routing in
    /// `AudioPlayerService.playPodcastEpisode` needs — the manifest carries no
    /// full show episode list, so auto-play-next is scoped to this one episode
    /// (mirrors `PodcastRecentEpisodesView`'s single-episode context).
    private func playOfflineEpisode(_ record: AudiobookDownloadRecord) {
        guard let absAPI,
              let (showID, episodeID) = AudiobookDownloadRecord.parseEpisodeRecordID(record.id) else { return }
        let episode = ABSEpisodeDTO(id: episodeID, title: record.title, duration: record.duration)
        let context = PodcastPlaybackContext(libraryItemId: showID, showTitle: record.author, episodes: [episode])
        audioPlayer.playPodcastEpisode(episode, via: absAPI, context: context)
    }

    /// Resolves track titles for the offline list from the library cache.
    private func resolveOfflineTrackTitles(downloads: [DownloadRecord]) {
        let store = NavidromeStore.shared
        var titles: [String: String] = [:]
        for record in downloads {
            if let track = try? store.writer.read({ db in
                try Track.fetchOne(db, key: record.id)
            }) {
                titles[record.id] = track.title
            }
        }
        offlineTrackTitles = titles
    }

    /// Plays downloaded tracks starting at the tapped track.
    private func playOfflineDownloads(startingAt trackID: String, downloads: [DownloadRecord]) {
        guard let api = api ?? providerManager.subsonicAPI else { return }
        guard !downloads.isEmpty else { return }

        let store = NavidromeStore.shared
        let queue: [Track] = downloads.map { record in
            (try? store.writer.read { db in try Track.fetchOne(db, key: record.id) })
                ?? minimalTrack(from: record)
        }
        let startIndex = downloads.firstIndex(where: { $0.id == trackID }) ?? 0
        audioPlayer.setQueue(queue, startIndex: startIndex, via: api)
    }

    // MARK: - Library browser (dispatches to mode-specific view)

    @ViewBuilder
    private func libraryBrowser(vm: NavidromeLibraryViewModel, api: NavidromeAPI) -> some View {
        switch browseMode {
        case .artists:
            ArtistBrowserView(viewModel: vm, api: api)
        case .albums:
            BrowseAlbumsView(viewModel: vm, api: api)
        case .genres:
            GenreListView(viewModel: vm, api: api)
        case .playlists:
            PlaylistListView(viewModel: vm, api: api)
        }
    }
}

// MARK: - Artist browser (0xy.3)

/// Artist list for the Music tab.  Declared as a standalone view with an
/// `@ObservedObject` view model so it re-renders when `artistsState` changes.
///
/// (Previously inlined in `MusicLibraryView` as a method, where the view model
/// was held in plain `@State` and therefore not observed — the list spinner
/// never resolved until an unrelated `@State` change forced a body recompute.
/// bug juv.)
struct ArtistBrowserView: View {
    @ObservedObject var viewModel: NavidromeLibraryViewModel
    let api: NavidromeAPI

    var body: some View {
        switch viewModel.artistsState {
        case .idle, .loading:
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Loading artists…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .empty:
            ScrollView {
                EmptyStateView(
                    title: "No Artists",
                    systemImage: "music.mic",
                    description: "Your Navidrome library has no artists yet."
                )
                .containerRelativeFrame([.horizontal, .vertical])
            }

        case .error(let message):
            ScrollView {
                VStack(spacing: 16) {
                    EmptyStateView(
                        title: "Couldn't Load Artists",
                        systemImage: "exclamationmark.triangle",
                        description: message
                    )
                    Button {
                        Task { await viewModel.loadArtists() }
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
                .containerRelativeFrame([.horizontal, .vertical])
            }

        case .loaded:
            List(viewModel.artists, id: \.id) { artist in
                NavigationLink {
                    ArtistDetailView(viewModel: viewModel, artist: artist, api: api)
                } label: {
                    ArtistRowView(artist: artist, api: api)
                }
                .accessibilityLabel(artist.name)
                .accessibilityHint("Browse albums by \(artist.name)")
            }
            .listStyle(.plain)
            .refreshable {
                await viewModel.loadArtists()
            }
        }
    }
}

// MARK: - Book search (3h6.9)

/// Client-side title/author search over the already-loaded Books list — no ABS
/// server-search endpoint exists, so this filters `viewModel.books` in memory.
/// ponytail: linear scan over an in-memory array; fine at library-list scale,
/// revisit only if book counts get large enough to matter.
struct BookSearchResultsView: View {
    @ObservedObject var viewModel: AudiobookshelfLibraryViewModel
    let query: String

    private var results: [Audiobook] {
        viewModel.books.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || ($0.author?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        if results.isEmpty {
            ScrollView {
                EmptyStateView(
                    title: "No Results",
                    systemImage: "magnifyingglass",
                    description: "No books match \"\(query)\"."
                )
                .containerRelativeFrame([.horizontal, .vertical])
            }
        } else {
            List(results, id: \.id) { book in
                NavigationLink {
                    AudiobookDetailView(viewModel: viewModel, book: book)
                } label: {
                    AudiobookRowView(book: book, coverURL: viewModel.coverURLs[book.id])
                }
                .accessibilityLabel(book.title)
                .accessibilityHint("Open \(book.title)")
            }
            .listStyle(.plain)
        }
    }
}

// MARK: - Offline track row (l31.3)

/// A simple row used in the offline-mode downloaded-tracks list.
private struct OfflineTrackRow: View {
    let record: DownloadRecord
    let title: String?
    let onPlay: () -> Void

    private var displayTitle: String {
        title ?? record.id
    }

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.blue)
                    .accessibilityHidden(true)

                Text(displayTitle)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Spacer()

                Image(systemName: "play.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(displayTitle)
        .accessibilityHint("Play downloaded track")
    }
}

// MARK: - Offline download row (uxc.1)

/// Tap-to-play row for a downloaded audiobook or podcast episode in the
/// offline browser — same shape as `OfflineTrackRow`, generalized to take a
/// title/subtitle/icon instead of a Navidrome `DownloadRecord`.
private struct OfflineDownloadRow: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .foregroundStyle(.blue)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Image(systemName: "play.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityHint("Play downloaded item")
    }
}

// MARK: - Artist row

struct ArtistRowView: View {
    let artist: Artist
    let api: NavidromeAPI

    var body: some View {
        HStack(spacing: 12) {
            SubsonicCoverArt(
                api: api,
                coverArtID: artist.coverArt,
                size: 80,
                width: 44,
                height: 44,
                cornerRadius: 8
            )
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(artist.name)
                    .font(.body)
                    .foregroundStyle(.primary)
                if artist.albumCount > 0 {
                    Text("\(artist.albumCount) \(artist.albumCount == 1 ? "album" : "albums")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Conditional searchable (b42)

private extension View {
    /// Applies `.searchable` only in Music mode. `.searchable` can't be toggled
    /// with a plain `if` inside a modifier chain, so branch the whole view here.
    /// ponytail: two-branch @ViewBuilder is the standard SwiftUI way to make
    /// .searchable conditional; a shared ViewModifier can't drop the modifier.
    @ViewBuilder
    func searchableIfMusic(isMusic: Bool, text: Binding<String>, prompt: String) -> some View {
        if isMusic {
            self.searchable(
                text: text,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: prompt
            )
        } else {
            self
        }
    }
}

// MARK: - Preview

#Preview {
    MusicLibraryView()
        .environmentObject(ProviderManager())
        .environmentObject(DownloadManager.shared)
        .environmentObject(AudioPlayerService.shared)
        .environmentObject(SettingsViewModel(audioPlayer: AudioPlayerService.shared))
}
#endif // canImport(UIKit)
