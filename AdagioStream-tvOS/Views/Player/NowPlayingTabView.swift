import SwiftUI

struct NowPlayingTabView: View {
    @EnvironmentObject private var audioPlayer: AudioPlayerService

    var body: some View {
        if let channel = audioPlayer.currentChannel {
            playingContent(for: channel)
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            Image(systemName: "play.slash")
                .font(.system(size: 96))
                .foregroundStyle(.secondary)
            Text("Nothing playing")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("Pick a channel from the Channels tab to start streaming.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .padding(80)
    }

    private func playingContent(for channel: Channel) -> some View {
        VStack(spacing: 40) {
            artwork(for: channel)
                .frame(width: 360, height: 360)
                .clipShape(RoundedRectangle(cornerRadius: 24))

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
    }

    private var transportControls: some View {
        HStack(spacing: 32) {
            Button(action: { audioPlayer.playPrevious() }) {
                Image(systemName: "backward.fill")
                    .font(.title)
                    .frame(width: 72, height: 72)
            }

            Button(action: { audioPlayer.togglePlayPause() }) {
                Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                    .font(.largeTitle)
                    .frame(width: 96, height: 96)
            }

            Button(action: { audioPlayer.playNext() }) {
                Image(systemName: "forward.fill")
                    .font(.title)
                    .frame(width: 72, height: 72)
            }
        }
    }
}
