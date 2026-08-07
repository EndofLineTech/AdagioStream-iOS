import SwiftUI

struct NowPlayingTabView: View {
    @EnvironmentObject private var audioPlayer: AudioPlayerService
    @EnvironmentObject private var providerManager: ProviderManager

    var body: some View {
        if let book = audioPlayer.currentAudiobook {
            audiobookContent(for: book)
        } else if let channel = audioPlayer.currentChannel {
            playingContent(for: channel)
        } else {
            emptyState
        }
    }

    // MARK: - Audiobook now-playing (xmq)

    private func audiobookContent(for book: Audiobook) -> some View {
        VStack(spacing: 40) {
            audiobookArtwork
                .frame(width: 360, height: 360)
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .accessibilityHidden(true)

            VStack(spacing: 12) {
                Text(book.title)
                    .font(.largeTitle)
                if let chapter = audioPlayer.currentChapter {
                    Text(chapter.title)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                Text("\(Self.formatTime(audioPlayer.audiobookGlobalTime)) / \(Self.formatTime(audioPlayer.audiobookDuration ?? 0))")
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)

            audiobookTransport
        }
        .padding(60)
    }

    @ViewBuilder private var audiobookArtwork: some View {
        if let url = audioPlayer.nowPlayingArtworkURL {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                audiobookPlaceholderArt
            }
        } else {
            audiobookPlaceholderArt
        }
    }

    private var audiobookPlaceholderArt: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24).fill(.secondary.opacity(0.2))
            Image(systemName: "book.closed").font(.system(size: 120)).foregroundStyle(.secondary)
        }
        .accessibilityHidden(true)
    }

    private var audiobookTransport: some View {
        HStack(spacing: 32) {
            Button(action: { audioPlayer.skipToPreviousChapter() }) {
                Image(systemName: "backward.fill")
                    .font(.title)
                    .frame(width: 72, height: 72)
            }
            .accessibilityLabel("Previous chapter")

            Button(action: { audioPlayer.togglePlayPause() }) {
                Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                    .font(.largeTitle)
                    .frame(width: 96, height: 96)
            }
            .accessibilityLabel(audioPlayer.isPlaying ? "Pause" : "Play")

            Button(action: { audioPlayer.skipToNextChapter() }) {
                Image(systemName: "forward.fill")
                    .font(.title)
                    .frame(width: 72, height: 72)
            }
            .accessibilityLabel("Next chapter")
        }
    }

    static func formatTime(_ seconds: Double) -> String {
        let s = Int(max(0, seconds).rounded())
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            Image(systemName: "play.slash")
                .font(.system(size: 96))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Nothing playing")
                .font(.title)
                .foregroundStyle(.secondary)
            Text(emptyStateHint)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .padding(80)
    }

    /// uxa.5: mentions Audiobooks/Podcasts only when those tabs are actually
    /// visible — same ABS-provider gate RootTabView uses to show them.
    private var emptyStateHint: String {
        providerManager.audiobookshelfAPI != nil
            ? "Pick something from Channels, Audiobooks, or Podcasts to start."
            : "Pick a channel from the Channels tab to start streaming."
    }

    private func playingContent(for channel: Channel) -> some View {
        VStack(spacing: 40) {
            artwork(for: channel)
                .frame(width: 360, height: 360)
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .accessibilityHidden(true)

            VStack(spacing: 12) {
                Text(channel.name)
                    .font(.largeTitle)
                if let title = audioPlayer.streamTitle {
                    Text(title)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                if let artist = audioPlayer.streamArtist {
                    Text(artist)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center)

            transportControls
        }
        .padding(60)
    }

    @ViewBuilder
    private func artwork(for channel: Channel) -> some View {
        if let url = channel.logoURL {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                placeholderArt
            }
        } else {
            placeholderArt
        }
    }

    private var placeholderArt: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24)
                .fill(.secondary.opacity(0.2))
            Image(systemName: "radio")
                .font(.system(size: 120))
                .foregroundStyle(.secondary)
        }
        .accessibilityHidden(true)
    }

    private var transportControls: some View {
        HStack(spacing: 32) {
            Button(action: { audioPlayer.playPrevious() }) {
                Image(systemName: "backward.fill")
                    .font(.title)
                    .frame(width: 72, height: 72)
            }
            .accessibilityLabel("Previous channel")

            Button(action: { audioPlayer.togglePlayPause() }) {
                Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                    .font(.largeTitle)
                    .frame(width: 96, height: 96)
            }
            .accessibilityLabel(audioPlayer.isPlaying ? "Pause" : "Play")

            Button(action: { audioPlayer.playNext() }) {
                Image(systemName: "forward.fill")
                    .font(.title)
                    .frame(width: 72, height: 72)
            }
            .accessibilityLabel("Next channel")
        }
    }
}
