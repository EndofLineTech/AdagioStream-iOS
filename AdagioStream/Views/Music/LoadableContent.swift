// t96.11 — Shared loading/empty/error scaffold for the music browse screens.
//
// AlbumDetailView, ArtistDetailView, BrowseAlbumsView, GenreBrowseView (x2),
// SearchResultsView, and PlaylistBrowseView (x2) each copy-pasted the same
// LoadState switch (spinner → EmptyStateView → EmptyStateView+Retry → content).
// This view reproduces that exact visual shape once; call sites only supply
// the per-screen strings/icon and the loaded content.

import SwiftUI

/// Renders `state` using the loading/empty/error/loaded shape shared by the
/// Navidrome browse screens.
///
/// `.idle` is folded into the `.loading` spinner by default. SearchResultsView
/// is the one screen that treats `.idle` differently (a blank view while its
/// query is debouncing, not a spinner) — pass `idle:` to override.
struct LoadableContent<Loaded: View>: View {
    let state: LoadState
    let loadingText: String
    let emptyTitle: String
    let emptySystemImage: String
    let emptyDescription: String
    let errorTitle: String
    let retry: () -> Void
    var idle: AnyView? = nil
    @ViewBuilder let loaded: () -> Loaded

    var body: some View {
        switch state {
        case .idle where idle != nil:
            idle!

        case .idle, .loading:
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text(loadingText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .empty:
            ScrollView {
                EmptyStateView(
                    title: emptyTitle,
                    systemImage: emptySystemImage,
                    description: emptyDescription
                )
                .containerRelativeFrame([.horizontal, .vertical])
            }

        case .error(let message):
            ScrollView {
                VStack(spacing: 16) {
                    EmptyStateView(
                        title: errorTitle,
                        systemImage: "exclamationmark.triangle",
                        description: message
                    )
                    Button {
                        retry()
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
                .containerRelativeFrame([.horizontal, .vertical])
            }

        case .loaded:
            loaded()
        }
    }
}
