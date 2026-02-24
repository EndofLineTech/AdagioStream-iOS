import SwiftUI

struct MiniPlayerView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @State private var showNowPlaying = false

    var body: some View {
        HStack(spacing: 12) {
            // Channel logo + info — tapping opens full player
            Button {
                showNowPlaying = true
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        if let logoURL = audioPlayer.currentChannel?.logoURL {
                            RetryableAsyncImage(url: logoURL, width: 36, height: 36, cornerRadius: 6)
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
                        if let error = audioPlayer.error {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .lineLimit(1)
                        } else if !audioPlayer.statusText.isEmpty {
                            Text(audioPlayer.statusText)
                                .font(.caption)
                                .foregroundStyle(audioPlayer.isBuffering ? .orange : .secondary)
                        }
                    }

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Play/Pause button
            Button {
                audioPlayer.togglePlayPause()
            } label: {
                Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)

            // Stop button
            Button {
                audioPlayer.stop()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .glassBackground()
        .glassContainer()
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView()
        }
    }
}
