// 65x.2 — Reusable heart/star toggle button for Navidrome music library items.
// 65x.3 — NavidromeStarIndicator (read-only) and navidromePlayCountText helper.
//
// FAVORITES SEPARATION NOTE:
// This component is for Navidrome server-side starring of music library items
// (tracks, albums, artists). It is entirely separate from the app's radio-channel
// favorites system (ProviderManager.favoriteOrder / toggleFavorite), which manages
// LOCAL favorites for live-stream channels. These two domains must not be mixed.

// MARK: - Play count text helper (65x.3)

/// Returns a formatted play-count string for display (e.g. "▶ 42").
/// Returns `nil` when `playCount` is nil or zero — callers should omit the label entirely.
///
/// Pure function — testable without any UI state. Platform-agnostic (no UIKit import).
func navidromePlayCountText(_ playCount: Int?) -> String? {
    guard let count = playCount, count > 0 else { return nil }
    return "▶ \(count)"
}

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
        .accessibilityValue(starred ? "Saved" : "Not saved")
    }
}

// MARK: - NavidromeStarIndicator (65x.3)

/// A compact read-only heart indicator for starred items in browse row/cell contexts.
///
/// Unlike `NavidromeStarButton` this is non-interactive — it is a static
/// indicator only.  Used in album grid cells, search result rows, and genre
/// track rows where the full interactive toggle would be too prominent.
///
/// Only rendered when `starred == true` to avoid visual noise on unstarred items.
struct NavidromeStarIndicator: View {
    let starred: Bool

    var body: some View {
        if starred {
            Image(systemName: "heart.fill")
                .font(.caption2)
                .foregroundStyle(Color.red.opacity(0.85))
                .accessibilityHidden(true)   // row-level accessibilityLabel carries this info
        }
    }
}

// MARK: - Preview

#Preview("Save states") {
    HStack(spacing: 20) {
        NavidromeStarButton(starred: false, accessibilityLabel: "Save track") {}
        NavidromeStarButton(starred: true, accessibilityLabel: "Remove track from Saved") {}
    }
    .padding()
}

#Preview("Save indicator") {
    HStack(spacing: 12) {
        NavidromeStarIndicator(starred: false)
        NavidromeStarIndicator(starred: true)
    }
    .padding()
}
#endif // canImport(UIKit)
