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
        switch viewModel.albumsState {
        case .idle, .loading:
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Loading albums…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .empty:
            ScrollView {
                EmptyStateView(
                    title: "No Albums",
                    systemImage: "square.stack",
                    description: "\(artist.name) has no albums in your library."
                )
                .containerRelativeFrame([.horizontal, .vertical])
            }

        case .error(let message):
            ScrollView {
                VStack(spacing: 16) {
                    EmptyStateView(
                        title: "Couldn't Load Albums",
                        systemImage: "exclamationmark.triangle",
                        description: message
                    )
                    Button {
                        Task { await viewModel.loadAlbums(for: artist) }
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
                .containerRelativeFrame([.horizontal, .vertical])
            }

        case .loaded:
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
                    .accessibilityLabel(album.title)
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

struct AlbumGridCell: View {
    let album: Album
    let api: NavidromeAPI

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

            Text(album.title)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
                .lineLimit(2)

            if let year = album.year {
                Text(String(year))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
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
