// t96.12 — Unified track row for the music browse screens.
//
// Replaces three near-identical rows (AlbumDetailView's TrackRowView,
// PlaylistBrowseView's PlaylistTrackRowView, GenreBrowseView's
// GenreTrackRowView) with one view driven by optional slots, generalized
// from PlaylistTrackRowView which already modeled the optional
// star/download/inline-play pattern.
//
// Leading badge differs per screen:
//   - Album: track number (or blank) — no cover art, no inline controls;
//     love/download live in the row's swipe action + context menu instead,
//     so the title gets full width (bug sbx).
//   - Playlist: always-numbered position badge + optional inline star/
//     download buttons + inline play button.
//   - Genre: small cover-art thumbnail + optional passive star indicator +
//     inline play button.
//
// Each caller supplies only the slots it needs; unused slots render nothing,
// so each screen's visuals are unchanged from before this consolidation.

#if canImport(UIKit)
import SwiftUI

struct TrackRowView: View {
    let track: Track

    /// Leading content before the title. Album rows show a track-number
    /// badge; playlist rows show a position badge; genre rows show cover art.
    enum Leading {
        case trackNumber(Int?)
        case position(Int)
        case coverArt(api: NavidromeAPI, coverArtID: String?)
    }
    var leading: Leading = .trackNumber(nil)

    /// Optional secondary line under the title (artist name or genre name).
    var subtitle: String? = nil

    /// 65x.3: Passive starred indicator (genre rows) — shown next to the title,
    /// not interactive. Mutually exclusive with `starred`/`onToggleStar` below.
    var starIndicator: Bool = false

    /// 65x.2: Interactive star toggle (playlist rows). When both `starred` and
    /// `onToggleStar` are non-nil, a heart button is shown after the duration.
    var starred: Bool? = nil
    var onToggleStar: (() -> Void)? = nil

    /// l31.2: Download affordance (playlist rows). When non-nil, shows a
    /// TrackDownloadButton after the star slot.
    var downloadAPI: NavidromeAPI? = nil

    /// Inline play button (genre + playlist rows). Album rows omit this —
    /// tap-to-play on the whole row is still always active.
    var showsInlinePlayButton: Bool = false

    let onPlay: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            leadingView

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(track.title)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if starIndicator {
                        NavidromeStarIndicator(starred: true)
                    }
                }

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let duration = track.duration {
                Text(duration.durationString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityHidden(true)
            }

            if let isStarred = starred, let toggle = onToggleStar {
                NavidromeStarButton(
                    starred: isStarred,
                    accessibilityLabel: isStarred ? "Unstar \(track.title)" : "Star \(track.title)",
                    onToggle: toggle
                )
            }

            if let api = downloadAPI {
                TrackDownloadButton(track: track, api: api)
            }

            if showsInlinePlayButton {
                Button {
                    onPlay()
                } label: {
                    Image(systemName: "play.circle")
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play \(track.title)")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onPlay()
        }
    }

    @ViewBuilder
    private var leadingView: some View {
        switch leading {
        case .trackNumber(let number):
            Group {
                if let number {
                    Text(String(number))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .trailing)
                } else {
                    Spacer()
                        .frame(width: 28)
                }
            }
            .accessibilityHidden(true)

        case .position(let position):
            Text(String(position))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
                .accessibilityHidden(true)

        case .coverArt(let api, let coverArtID):
            SubsonicCoverArt(
                api: api,
                coverArtID: coverArtID,
                size: 80,
                width: 40,
                height: 40,
                cornerRadius: 6
            )
            .accessibilityHidden(true)
        }
    }
}
#endif // canImport(UIKit)
