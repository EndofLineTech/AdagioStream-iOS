import SwiftUI

struct MiniPlayerView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @State private var showNowPlaying = false

    var body: some View {
        Button {
            showNowPlaying = true
        } label: {
            HStack(spacing: 12) {
                // Channel logo
                ZStack {
                    if let logoURL = audioPlayer.currentChannel?.logoURL {
                        AsyncImage(url: logoURL) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        } placeholder: {
                            Image(systemName: "radio")
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        Image(systemName: "radio")
                            .frame(width: 36, height: 36)
                            .foregroundStyle(.secondary)
                    }

                    if audioPlayer.isBuffering {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.ultraThinMaterial)
                            .frame(width: 36, height: 36)
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(audioPlayer.currentChannel?.name ?? "")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if !audioPlayer.statusText.isEmpty {
                        Text(audioPlayer.statusText)
                            .font(.caption)
                            .foregroundStyle(audioPlayer.isBuffering ? .orange : .secondary)
                    }
                }

                Spacer()

                // Play/Pause button
                Button {
                    audioPlayer.togglePlayPause()
                } label: {
                    Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                }
                .buttonStyle(InteractiveGlassButtonStyle())

                // Stop button
                Button {
                    audioPlayer.stop()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(InteractiveGlassButtonStyle())
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .glassBackground()
        }
        .buttonStyle(.plain)
        .glassContainer()
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView()
        }
    }
}
