import SwiftUI

struct SavedSongRowView: View {
    let song: SavedSong

    var body: some View {
        HStack(spacing: 12) {
            if let artworkURL = song.artworkURL {
                RetryableAsyncImage(url: artworkURL, width: 40, height: 40, cornerRadius: 8)
            } else if let logoURL = song.channelLogoURL {
                RetryableAsyncImage(url: logoURL, width: 40, height: 40, cornerRadius: 8)
            } else {
                Image(systemName: "music.note")
                    .frame(width: 40, height: 40)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Text(song.artistDisplay)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(song.channelName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
