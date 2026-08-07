// 0xy.4 — Browse albums by type: newest / recent / frequent / random / A–Z
//
// Displays a LazyVGrid of albums fetched via getAlbumList2.  Reuses
// AlbumGridCell from ArtistDetailView.  Tapping an album navigates to
// AlbumDetailView (identical to the artist→album path from 0xy.3).
//
// A Picker in the toolbar lets the user switch between the five AlbumListType
// modes.  Each mode change re-fetches immediately; loading/error/empty states
// mirror the ArtistDetailView pattern.
//
// Pagination: a single page of NavidromeLibraryViewModel.albumBrowsePageSize
// (50) is fetched.  No load-more / infinite scroll is implemented in 0xy.4.

#if canImport(UIKit)
import SwiftUI

struct BrowseAlbumsView: View {
    @ObservedObject var viewModel: NavidromeLibraryViewModel
    let api: NavidromeAPI

    @State private var selectedType: NavidromeAPI.AlbumListType = .newest

    @Environment(\.horizontalSizeClass) private var sizeClass
    private var columns: [GridItem] {
        let count = sizeClass == .regular ? 3 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 16), count: count)
    }

    var body: some View {
        content
            .navigationTitle(selectedType.displayName)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    albumTypePicker
                }
            }
            .task {
                // Load on first appear or whenever selectedType changes.
                await loadIfNeeded()
            }
            .onChange(of: selectedType) { _, _ in
                Task { await loadForCurrentType() }
            }
    }

    // MARK: - Album type picker

    private var albumTypePicker: some View {
        Menu {
            ForEach(NavidromeAPI.AlbumListType.allBrowseCases, id: \.self) { mode in
                Button {
                    selectedType = mode
                } label: {
                    Label(mode.displayName, systemImage: mode.systemImage)
                }
                .accessibilityLabel("Browse \(mode.displayName) albums")
            }
        } label: {
            Label("Sort", systemImage: "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel("Album browse mode")
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        LoadableContent(
            state: viewModel.browseAlbumsState,
            loadingText: "Loading albums…",
            emptyTitle: "No Albums",
            emptySystemImage: "square.stack",
            emptyDescription: "No albums found for \"\(selectedType.displayName)\".",
            errorTitle: "Couldn't Load Albums",
            retry: { Task { await loadForCurrentType() } }
        ) {
            albumGrid
        }
    }

    private var albumGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(viewModel.browseAlbums, id: \.id) { album in
                    NavigationLink {
                        AlbumDetailView(viewModel: viewModel, album: album, api: api)
                    } label: {
                        // 65x.3: Pass star state so the cell can show starred indicator + play count.
                        AlbumGridCell(
                            album: album,
                            api: api,
                            starState: viewModel.browseAlbumStarStates[album.id]
                        )
                    }
                    .buttonStyle(.plain)
                    // 65x.3: accessibilityLabel is now built inside AlbumGridCell
                    .accessibilityHint(
                        album.year.map { "Released \($0), navigate to tracks" }
                            ?? "Navigate to tracks"
                    )
                    // uxc.2: reaching the last album loads the next page —
                    // Subsonic's getAlbumList2 supports offset pagination.
                    .task(id: album.id) {
                        if BrowsePagination.shouldLoadMore(
                            itemID: album.id,
                            lastItemID: viewModel.browseAlbums.last?.id,
                            hasMore: viewModel.browseAlbumsHasMore,
                            isLoadingMore: viewModel.isLoadingMoreBrowseAlbums
                        ) {
                            await viewModel.loadMoreBrowseAlbums()
                        }
                    }
                }
            }
            .padding(16)

            if viewModel.isLoadingMoreBrowseAlbums {
                ProgressView()
                    .padding(.bottom, 16)
            }
        }
        .refreshable {
            await loadForCurrentType()
        }
    }

    // MARK: - Load helpers

    private func loadIfNeeded() async {
        // Load only if the currently cached type doesn't match or we haven't loaded yet.
        if viewModel.browseAlbumsType != selectedType
            || viewModel.browseAlbumsState == .idle {
            await loadForCurrentType()
        }
    }

    private func loadForCurrentType() async {
        await viewModel.loadBrowseAlbums(type: selectedType)
    }
}

// MARK: - AlbumListType display helpers (0xy.4)

extension NavidromeAPI.AlbumListType {
    /// Human-readable label shown in the picker and navigation title.
    var displayName: String {
        switch self {
        case .newest:           return "Newest"
        case .recent:           return "Recently Played"
        case .frequent:         return "Most Played"
        case .random:           return "Random"
        case .alphabeticalByName: return "A–Z"
        }
    }

    /// SF Symbol for the picker menu item.
    var systemImage: String {
        switch self {
        case .newest:           return "sparkles"
        case .recent:           return "clock"
        case .frequent:         return "chart.bar"
        case .random:           return "shuffle"
        case .alphabeticalByName: return "textformat.abc"
        }
    }

    /// Ordered list of modes shown in the browse picker.
    static var allBrowseCases: [NavidromeAPI.AlbumListType] {
        [.newest, .recent, .frequent, .random, .alphabeticalByName]
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        BrowseAlbumsView(
            viewModel: NavidromeLibraryViewModel(
                api: NavidromeAPI(
                    host: URL(string: "https://demo.navidrome.org")!,
                    username: "demo",
                    password: "demo"
                )
            ),
            api: NavidromeAPI(
                host: URL(string: "https://demo.navidrome.org")!,
                username: "demo",
                password: "demo"
            )
        )
    }
}
#endif // canImport(UIKit)
