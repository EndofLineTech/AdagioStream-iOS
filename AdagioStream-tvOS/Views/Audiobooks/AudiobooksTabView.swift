import SwiftUI

// Audiobookshelf E4 / ciu.2 — tvOS audiobook browsing.
//
// Parallel to ChannelsTabView: focus-engine list driven by the SHARED
// AudiobookshelfLibraryViewModel (same fetch/cover/resume logic as iOS &
// CarPlay). The VM is built once the ABS provider resolves; the tab is only
// mounted when a provider exists (RootTabView gates it).
struct AudiobooksTabView: View {
    @EnvironmentObject private var providerManager: ProviderManager

    var body: some View {
        NavigationStack {
            Group {
                if let api = providerManager.audiobookshelfAPI {
                    AudiobooksListView(viewModel: AudiobookshelfLibraryViewModel(api: api))
                } else {
                    Text("No Audiobookshelf server configured.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Audiobooks")
        }
    }
}

private struct AudiobooksListView: View {
    @StateObject var viewModel: AudiobookshelfLibraryViewModel

    var body: some View {
        Group {
            switch viewModel.booksState {
            case .idle, .loading:
                ProgressView("Loading audiobooks…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .empty:
                Text("No audiobooks in your library.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .error(let message):
                VStack(spacing: 24) {
                    Text("Couldn't load audiobooks").font(.title2)
                    Text(message).foregroundStyle(.secondary)
                    Button("Retry") { Task { await viewModel.loadBooks() } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded:
                List(viewModel.books, id: \.id) { book in
                    NavigationLink {
                        AudiobookDetailTVView(viewModel: viewModel, book: book)
                    } label: {
                        AudiobookRowTVView(book: book, coverURL: viewModel.coverURLs[book.id])
                    }
                }
            }
        }
        .task { await viewModel.loadBooks() }
    }
}

struct AudiobookRowTVView: View {
    let book: Audiobook
    let coverURL: URL?

    var body: some View {
        HStack(spacing: 20) {
            cover
            VStack(alignment: .leading, spacing: 4) {
                Text(book.title).font(.title3).foregroundStyle(.primary).lineLimit(2)
                if let author = book.author, !author.isEmpty {
                    Text(author).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                if book.isFinished {
                    Label("Finished", systemImage: "checkmark.circle.fill").font(.caption)
                } else if book.progress > 0 {
                    ProgressView(value: min(1, book.progress)).tint(.accentColor)
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
        Image(systemName: "book.closed")
            .font(.system(size: 36))
            .foregroundStyle(.secondary)
    }
}
