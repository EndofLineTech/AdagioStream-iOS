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

    var body: some View {
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
        .hoverEffect(.highlight)
        .draggable(channel)
        .onTapGesture { onTap() }
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
}
