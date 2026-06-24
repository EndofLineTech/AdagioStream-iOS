// 0xy.3 — Navidrome browse UI: root artists list
// 0xy.4 — Extended with album-browse and genre-browse modes via a segmented Picker.
//
// MusicLibraryView is the NavigationStack root for the "Music" tab (mounted by
// 0xy.5).  It resolves the NavidromeAPI from ProviderManager.shared.subsonicAPI
// on first appear and builds the NavidromeLibraryViewModel from it.
//
// Self-contained NavigationStack — does NOT expect to be embedded in one.
//
// Browse modes (segmented Picker in the toolbar):
//   • Artists  — artist list → ArtistDetailView → AlbumDetailView (0xy.3)
//   • Albums   — BrowseAlbumsView with a type picker (newest/recent/frequent/random/A–Z)
//   • Genres   — GenreListView → GenreDetailView (0xy.4)

#if canImport(UIKit)
import SwiftUI

// MARK: - Browse mode

/// Top-level browse mode selector for the Music tab.
enum MusicBrowseMode: String, CaseIterable {
    case artists = "Artists"
    case albums  = "Albums"
    case genres  = "Genres"
}

// MARK: - MusicLibraryView

public struct MusicLibraryView: View {

    @EnvironmentObject private var providerManager: ProviderManager

    // State for the resolved API.  Resolved once in .task so that the entire
    // NavigationStack shares a single API instance (and therefore a single cache
    // salt set) for the lifetime of this view.
    @State private var api: NavidromeAPI?

    // The view-model is created lazily once we have a valid API.
    @State private var viewModel: NavidromeLibraryViewModel?

    // Current browse mode — persists across tab switches.
    @State private var browseMode: MusicBrowseMode = .artists

    public init() {}

    public var body: some View {
        NavigationStack {
            Group {
                if let vm = viewModel, let resolvedAPI = api {
                    libraryBrowser(vm: vm, api: resolvedAPI)
                } else if providerManager.subsonicAPI == nil {
                    ScrollView {
                        EmptyStateView(
                            title: "No Music Library",
                            systemImage: "music.note.house",
                            description: "Add a Navidrome/Subsonic account in Settings → Accounts."
                        )
                        .containerRelativeFrame([.horizontal, .vertical])
                    }
                } else {
                    ProgressView("Loading library…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Music")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    browseModeSelector
                }
            }
            .task {
                guard let resolved = providerManager.subsonicAPI else { return }
                if api == nil {
                    api = resolved
                    let vm = NavidromeLibraryViewModel(api: resolved)
                    viewModel = vm
                    await vm.loadArtists()
                }
            }
        }
    }

    // MARK: - Mode selector

    private var browseModeSelector: some View {
        Picker("Browse", selection: $browseMode) {
            ForEach(MusicBrowseMode.allCases, id: \.self) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 280)
        .accessibilityLabel("Browse mode")
        .accessibilityHint("Switch between Artists, Albums, and Genres")
    }

    // MARK: - Library browser (dispatches to mode-specific view)

    @ViewBuilder
    private func libraryBrowser(vm: NavidromeLibraryViewModel, api: NavidromeAPI) -> some View {
        switch browseMode {
        case .artists:
            artistBrowser(vm: vm, api: api)
        case .albums:
            BrowseAlbumsView(viewModel: vm, api: api)
        case .genres:
            GenreListView(viewModel: vm, api: api)
        }
    }

    // MARK: - Artist browser (0xy.3, unchanged)

    @ViewBuilder
    private func artistBrowser(vm: NavidromeLibraryViewModel, api: NavidromeAPI) -> some View {
        switch vm.artistsState {
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
                        Task { await vm.loadArtists() }
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
                .containerRelativeFrame([.horizontal, .vertical])
            }

        case .loaded:
            List(vm.artists, id: \.id) { artist in
                NavigationLink {
                    ArtistDetailView(viewModel: vm, artist: artist, api: api)
                } label: {
                    ArtistRowView(artist: artist, api: api)
                }
                .accessibilityLabel(artist.name)
                .accessibilityHint("Browse albums by \(artist.name)")
            }
            .listStyle(.plain)
            .refreshable {
                await vm.loadArtists()
            }
        }
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

// MARK: - Preview

#Preview {
    MusicLibraryView()
        .environmentObject(ProviderManager())
}
#endif // canImport(UIKit)
