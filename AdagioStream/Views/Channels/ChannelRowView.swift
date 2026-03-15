import SwiftUI

struct ChannelRowView: View {
    let channel: Channel
    var nowPlayingTrack: SXMTrack? = nil
    var currentProgram: EPGEntry? = nil
    var espnGame: ESPNGameInfo? = nil
    let onTap: () -> Void
    let onToggleFavorite: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Channel logo
            if let logoURL = channel.logoURL {
                RetryableAsyncImage(url: logoURL, width: 40, height: 40, cornerRadius: 8)
            } else {
                Image(systemName: "radio")
                    .frame(width: 40, height: 40)
                    .foregroundStyle(.secondary)
            }

            // Channel name + subtitle
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

            // Favorite button
            Button {
                onToggleFavorite()
            } label: {
                Image(systemName: channel.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(channel.isFavorite ? .yellow : .secondary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}
