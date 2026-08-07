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

    // uxd.5: lineLimit(1) over-truncates long titles at accessibility text
    // sizes; allow a second line once the user has opted into one.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var titleLineLimit: Int { dynamicTypeSize.isAccessibilitySize ? 2 : 1 }

    var body: some View {
        // uxd.4: the row used to be a plain HStack + .onTapGesture with no
        // accessibilityElement grouping — VoiceOver would enumerate every
        // Text separately AND every caller layers its own external
        // .accessibilityLabel/.accessibilityHint on top (AlbumDetailView,
        // PlaylistBrowseView, GenreBrowseView), which only produces one
        // coherent announcement once the root is a real Button: Button
        // collapses its non-interactive children into the caller-supplied
        // label while the star/download/inline-play Buttons below stay
        // independently focusable — same per-button-granularity model
        // ChannelRowView uses (uxd.1). No caller changes needed.
        //
        // beads_mobilemusic-uxh: this separately-focusable-nested-Buttons
        // model is PROVISIONAL pending real-device VoiceOver verification.
        // The codebase's other precedent for a nested interactive control in
        // a List row is DownloadsView.swift ~:268-301, which instead combines
        // the row into one accessibility element and exposes the nested
        // Button as an `.accessibilityAction(named:)`. If uxh's verification
        // finds the nested-Button model here doesn't announce/activate
        // correctly, fall back to DownloadsView's combine+accessibilityAction
        // model — see the matching note on ChannelRowView's Button.
        Button(action: onPlay) {
            HStack(spacing: 12) {
                leadingView

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(track.title)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .lineLimit(titleLineLimit)
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
                        accessibilityLabel: isStarred ? "Remove \(track.title) from Saved" : "Save \(track.title)",
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
        }
        .buttonStyle(.plain)
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
            // uxd.4: no longer blanket-hidden — SubsonicCoverArt manages its
            // own accessibilityHidden state so the failed-load retry button
            // stays reachable (see SubsonicCoverArt.swift).
            SubsonicCoverArt(
                api: api,
                coverArtID: coverArtID,
                size: 80,
                width: 40,
                height: 40,
                cornerRadius: 6
            )
        }
    }
}
#endif // canImport(UIKit)
