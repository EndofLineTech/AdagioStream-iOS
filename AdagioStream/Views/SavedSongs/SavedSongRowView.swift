import SwiftUI

struct SavedSongRowView: View {
    let song: SavedSong
    @Environment(\.openURL) private var openURL

    private var searchQuery: String {
        "\(song.title) \(song.artistDisplay)"
    }

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
        .contextMenu {
            Button {
                searchSpotify()
            } label: {
                Label("Search on Spotify", systemImage: "magnifyingglass")
            }
            Button {
                searchAppleMusic()
            } label: {
                Label("Search on Apple Music", systemImage: "magnifyingglass")
            }
        }
    }

    private func searchSpotify() {
        guard let encoded = searchQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return }
        let appURL = URL(string: "spotify:search:\(encoded)")!
        if UIApplication.shared.canOpenURL(appURL) {
            openURL(appURL)
        } else {
            openURL(URL(string: "https://open.spotify.com/search/\(encoded)")!)
        }
    }

    private func searchAppleMusic() {
        guard let encoded = searchQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return }
        let appURL = URL(string: "music://music.apple.com/us/search?term=\(encoded)")!
        if UIApplication.shared.canOpenURL(appURL) {
            openURL(appURL)
        } else {
            openURL(URL(string: "https://music.apple.com/us/search?term=\(encoded)")!)
        }
    }
}
