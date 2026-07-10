import SwiftUI

// Podcast E5 / hky.2 — tvOS podcast browsing.
//
// Parallel to AudiobooksTabView: focus-engine list driven by the SHARED
// AudiobookshelfLibraryViewModel (same fetch/cover data as iOS & CarPlay).
// The VM is built once the ABS provider resolves; the tab is only mounted
// when the provider has a podcast library (RootTabView gates it).
struct PodcastsTabView: View {
    @EnvironmentObject private var providerManager: ProviderManager

    var body: some View {
        NavigationStack {
            Group {
                if let api = providerManager.audiobookshelfAPI {
                    PodcastShowsListView(viewModel: AudiobookshelfLibraryViewModel(api: api))
                } else {
                    Text("No Audiobookshelf server configured.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Podcasts")
        }
    }
}

private struct PodcastShowsListView: View {
    @StateObject var viewModel: AudiobookshelfLibraryViewModel

    var body: some View {
        Group {
            switch viewModel.podcastShowsState {
            case .idle, .loading:
                ProgressView("Loading podcasts…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .empty:
                Text("No podcasts in your library.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .error(let message):
                VStack(spacing: 24) {
                    Text("Couldn't load podcasts").font(.title2)
                    Text(message).foregroundStyle(.secondary)
                    Button("Retry") { Task { await viewModel.loadPodcastShows() } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded:
                List(viewModel.podcastShows) { show in
                    NavigationLink {
                        PodcastShowDetailTVView(viewModel: viewModel, show: show)
                    } label: {
                        PodcastShowRowTVView(show: show, coverURL: viewModel.showCoverURLs[show.id])
                    }
                }
            }
        }
        .task { await viewModel.loadPodcastShows() }
    }
}

struct PodcastShowRowTVView: View {
    let show: PodcastShow
    let coverURL: URL?

    var body: some View {
        HStack(spacing: 20) {
            cover
            VStack(alignment: .leading, spacing: 4) {
                Text(show.title).font(.title3).foregroundStyle(.primary).lineLimit(2)
                if let author = show.author, !author.isEmpty {
                    Text(author).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder private var cover: some View {
        if let coverURL {
            AsyncImage(url: coverURL) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                placeholder
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            placeholder.frame(width: 72, height: 72)
        }
    }

    private var placeholder: some View {
        Image(systemName: "mic")
            .font(.system(size: 36))
            .foregroundStyle(.secondary)
    }
}
