// 0xy.3 — Navidrome browse UI: artist → albums
// 65x.2 — Star/unstar toggle for artist header
//
// Shows the albums for a single artist.  Navigates to AlbumDetailView on tap.
// Cover art displayed via SubsonicCoverArt; loading/error/empty states follow
// the ChannelListView pattern.

#if canImport(UIKit)
import SwiftUI

struct ArtistDetailView: View {
    @ObservedObject var viewModel: NavidromeLibraryViewModel
    let artist: Artist
    let api: NavidromeAPI

    // Grid configuration: 2 columns, fixed width adapts to horizontal size class.
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var columns: [GridItem] {
        let count = sizeClass == .regular ? 3 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 16), count: count)
    }

    var body: some View {
        content
            .navigationTitle(artist.name)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                // 65x.2: Artist star toggle in toolbar
                ToolbarItem(placement: .primaryAction) {
                    NavidromeStarButton(
                        starred: viewModel.selectedArtistStarState?.starred ?? false,
                        accessibilityLabel: "Star \(artist.name)"
                    ) {
                        Task { await viewModel.toggleStar(id: artist.id) }
                    }
                }
            }
            .task {
                // Re-load only if this artist differs from the previously loaded one.
                if viewModel.selectedArtist?.id != artist.id {
                    await viewModel.loadAlbums(for: artist)
                }
            }
            .alert(
                "Star Error",
                isPresented: Binding(
                    get: { viewModel.starError != nil },
                    set: { if !$0 { viewModel.clearStarError() } }
                )
            ) {
                Button("OK") { viewModel.clearStarError() }
            } message: {
                Text(viewModel.starError ?? "")
            }
    }

    @ViewBuilder
    private var content: some View {
        LoadableContent(
            state: viewModel.albumsState,
            loadingText: "Loading albums…",
            emptyTitle: "No Albums",
            emptySystemImage: "square.stack",
            emptyDescription: "\(artist.name) has no albums in your library.",
            errorTitle: "Couldn't Load Albums",
            retry: { Task { await viewModel.loadAlbums(for: artist) } }
        ) {
            albumGrid
        }
    }

    private var albumGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(viewModel.artistAlbums, id: \.id) { album in
                    NavigationLink {
                        AlbumDetailView(viewModel: viewModel, album: album, api: api)
                    } label: {
                        AlbumGridCell(album: album, api: api)
                    }
                    .buttonStyle(.plain)
                    // AlbumGridCell owns its accessibilityLabel (65x.3)
                    .accessibilityHint(
                        album.year.map { "Released \($0), navigate to tracks" }
                            ?? "Navigate to tracks"
                    )
                }
            }
            .padding(16)
        }
    }
}

// MARK: - Album grid cell

/// Grid cell for an album in browse/artist-detail views.
///
/// 65x.3: Accepts an optional `starState` to show a small starred indicator
/// and play count beneath the album title. Both are read-only display indicators;
/// the interactive star toggle remains in AlbumDetailView.
struct AlbumGridCell: View {
    let album: Album
    let api: NavidromeAPI
    /// 65x.3: When non-nil, enables the starred indicator and play-count caption.
    var starState: NavidromeAPI.StarState? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                SubsonicCoverArt(
                    api: api,
                    coverArtID: album.coverArt,
                    size: 300,
                    width: geo.size.width,
                    height: geo.size.width,
                    cornerRadius: 8
                )
            }
            .aspectRatio(1, contentMode: .fit)

            // Title row with optional starred indicator
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(album.title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                if let state = starState, state.starred {
                    NavidromeStarIndicator(starred: true)
                }
            }

            // Year + optional play count
            HStack(spacing: 4) {
                if let year = album.year {
                    Text(String(year))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let playText = navidromePlayCountText(starState?.playCount) {
                    Text(playText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        // 65x.3: Accessibility: include starred/play-count in the element label
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(albumGridCellAccessibilityLabel)
    }

    private var albumGridCellAccessibilityLabel: String {
        var parts: [String] = [album.title]
        if let year = album.year { parts.append(String(year)) }
        if let state = starState {
            if state.starred { parts.append("starred") }
            if let count = state.playCount, count > 0 {
                parts.append("played \(count) \(count == 1 ? "time" : "times")")
            }
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        ArtistDetailView(
            viewModel: NavidromeLibraryViewModel(
                api: NavidromeAPI(
                    host: URL(string: "https://demo.navidrome.org")!,
                    username: "demo",
                    password: "demo"
                )
            ),
            artist: Artist(id: "1", name: "Massive Attack", albumCount: 5, updatedAt: 0),
            api: NavidromeAPI(
                host: URL(string: "https://demo.navidrome.org")!,
                username: "demo",
                password: "demo"
            )
        )
    }
}
#endif // canImport(UIKit)
