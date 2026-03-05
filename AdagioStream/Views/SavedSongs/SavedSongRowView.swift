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
                Task { await searchAppleMusic() }
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

    private func searchAppleMusic() async {
        guard let encoded = searchQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return }
        // Use iTunes Search API to get a direct link to the song in Apple Music
        if let url = URL(string: "https://itunes.apple.com/search?term=\(encoded)&media=music&limit=1"),
           let (data, _) = try? await URLSession.shared.data(from: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let results = json["results"] as? [[String: Any]],
           let first = results.first,
           let trackURL = first["trackViewUrl"] as? String,
           let directURL = URL(string: trackURL) {
            openURL(directURL)
        } else {
            // Fallback to search page
            openURL(URL(string: "https://music.apple.com/us/search?term=\(encoded)")!)
        }
    }
}
