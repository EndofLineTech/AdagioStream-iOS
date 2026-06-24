// 65x.2 — Reusable heart/star toggle button for Navidrome music library items.
//
// FAVORITES SEPARATION NOTE:
// This component is for Navidrome server-side starring of music library items
// (tracks, albums, artists). It is entirely separate from the app's radio-channel
// favorites system (ProviderManager.favoriteOrder / toggleFavorite), which manages
// LOCAL favorites for live-stream channels. These two domains must not be mixed.

#if canImport(UIKit)
import SwiftUI

/// A heart-icon button that reflects and toggles the Navidrome server-side star state
/// for a music library item (track, album, or artist).
///
/// The button shows a filled red heart when starred, an unfilled secondary heart when not.
/// Tapping calls `onToggle` — the caller is responsible for the async operation.
struct NavidromeStarButton: View {
    /// Whether the item is currently starred on the server.
    let starred: Bool
    /// VoiceOver label for the button.
    let accessibilityLabel: String
    /// Called when the user taps the button.
    let onToggle: () -> Void

    var body: some View {
        Button {
            onToggle()
        } label: {
            Image(systemName: starred ? "heart.fill" : "heart")
                .font(.title3)
                .foregroundStyle(starred ? Color.red : Color.secondary)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(starred ? "Starred" : "Not starred")
    }
}

// MARK: - Preview

#Preview("Star states") {
    HStack(spacing: 20) {
        NavidromeStarButton(starred: false, accessibilityLabel: "Star track") {}
        NavidromeStarButton(starred: true, accessibilityLabel: "Unstar track") {}
    }
    .padding()
}
#endif // canImport(UIKit)
