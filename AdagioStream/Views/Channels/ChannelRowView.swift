import SwiftUI

struct ChannelRowView: View {
    let channel: Channel
    var nowPlayingTrack: SXMTrack? = nil
    var currentProgram: EPGEntry? = nil
    var espnGame: ESPNGameInfo? = nil
    let onTap: () -> Void
    let onToggleFavorite: () -> Void
    var onAddToPlaylist: (() -> Void)? = nil
    var onShowEPG: (() -> Void)? = nil

    @Environment(\.horizontalSizeClass) private var sizeClass

    private var logoSize: CGFloat { sizeClass == .regular ? 52 : 40 }
    private var logoRadius: CGFloat { sizeClass == .regular ? 10 : 8 }

    // beads_mobilemusic-uxh (record correction): commit 1847be0's message
    // cites UpNextView.queueRow as the nested-Button-in-List-row precedent —
    // wrong, queueRow has no nested Buttons. The real in-codebase precedent
    // for a row with a nested interactive control is
    // DownloadsView.swift ~:268-301 (DownloadedItemRowView), which uses a
    // DIFFERENT model: `.accessibilityElement(children: .combine)` +
    // `.accessibilityAction(named:)` for its nested delete Button, instead of
    // leaving it separately focusable.
    //
    // This row (and TrackRowView) instead use separately-focusable nested
    // Buttons for the favorite star / accessory controls — chosen so each
    // control keeps its own VoiceOver stop, label, and value without a
    // custom-action menu. That choice is PROVISIONAL pending real-device
    // VoiceOver verification (tracked by uxh); if verification finds the
    // nested-Button model doesn't announce/activate correctly, the fallback
    // is to convert to DownloadsView's combine+accessibilityAction model.
    // Two models coexisting was drift — this comment is the settlement so it
    // stops here: new rows should default to the nested-Button model unless
    // uxh's verification says otherwise.
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                if let logoURL = channel.logoURL {
                    RetryableAsyncImage(url: logoURL, width: logoSize, height: logoSize, cornerRadius: logoRadius)
                } else {
                    Image(systemName: "radio")
                        .frame(width: logoSize, height: logoSize)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                    if let track = nowPlayingTrack {
                        Text("\(track.artistDisplay) — \(track.title)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if let game = espnGame {
                        Text(game.displayText)
                            .font(.caption)
                            .foregroundStyle(game.state == .live ? .primary : .secondary)
                            .lineLimit(1)
                    } else if let program = currentProgram {
                        Text(program.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(channel.group)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // uxd.1: the favorite star is its own focusable control — SwiftUI
                // exposes nested interactive elements as separate accessibility
                // stops even inside a parent Button's label, so this doesn't get
                // swallowed by the row's combined label below.
                Button {
                    onToggleFavorite()
                } label: {
                    Image(systemName: channel.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(channel.isFavorite ? .yellow : .secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(channel.isFavorite ? "Remove \(channel.name) from favorites" : "Add \(channel.name) to favorites")
                .accessibilityValue(channel.isFavorite ? "Favorited" : "Not favorited")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.accessibilityLabel(
            channelName: channel.name,
            group: channel.group,
            isFavorite: channel.isFavorite,
            nowPlayingTrack: nowPlayingTrack,
            espnGame: espnGame,
            currentProgram: currentProgram
        ))
        .accessibilityHint("Double tap to listen")
        .hoverEffect(.highlight)
        .draggable(channel)
        .contextMenu {
            if let onShowEPG {
                Button {
                    onShowEPG()
                } label: {
                    Label("Program Guide", systemImage: "calendar")
                }
            }
            if let onAddToPlaylist {
                Button {
                    onAddToPlaylist()
                } label: {
                    Label("Add to M3U", systemImage: "music.note.list")
                }
            }
        }
        .swipeActions(edge: .leading) {
            // uxc.5: visible entry point for the program guide — previously
            // context-menu-only. Kept additive/minimal so it composes with
            // uxd.1's planned row-as-Button rewrite for VoiceOver.
            if let onShowEPG {
                Button {
                    onShowEPG()
                } label: {
                    Label("Program Guide", systemImage: "calendar")
                }
                .tint(.blue)
            }
            if let onAddToPlaylist {
                Button {
                    onAddToPlaylist()
                } label: {
                    Label("Add to M3U", systemImage: "music.note.list")
                }
                .tint(.purple)
            }
        }
    }

    /// uxd.1: combined VoiceOver label for the row — channel name plus whatever
    /// dynamic now-playing state is currently shown (track > game > EPG program
    /// > group), plus favorited state. Pure function so it's unit-testable
    /// without spinning up SwiftUI.
    static func accessibilityLabel(
        channelName: String,
        group: String,
        isFavorite: Bool,
        nowPlayingTrack: SXMTrack?,
        espnGame: ESPNGameInfo?,
        currentProgram: EPGEntry?
    ) -> String {
        var parts = [channelName]
        if let track = nowPlayingTrack {
            parts.append("\(track.artistDisplay) — \(track.title)")
        } else if let game = espnGame {
            parts.append(game.displayText)
        } else if let program = currentProgram {
            parts.append(program.title)
        } else {
            parts.append(group)
        }
        if isFavorite {
            parts.append("Favorited")
        }
        return parts.joined(separator: ", ")
    }
}
