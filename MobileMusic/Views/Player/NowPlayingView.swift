import SwiftUI

struct NowPlayingView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @EnvironmentObject var providerManager: ProviderManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                // Channel artwork
                if let logoURL = audioPlayer.currentChannel?.logoURL {
                    AsyncImage(url: logoURL) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } placeholder: {
                        channelPlaceholder
                    }
                    .frame(width: 200, height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .shadow(radius: 10)
                } else {
                    channelPlaceholder
                }

                // Channel info
                VStack(spacing: 8) {
                    Text(audioPlayer.currentChannel?.name ?? "Not Playing")
                        .font(.title2)
                        .fontWeight(.bold)
                        .multilineTextAlignment(.center)

                    Text(audioPlayer.currentChannel?.group ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if let epg = currentEPG {
                        Text(epg.title)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                }

                // Playback controls
                HStack(spacing: 40) {
                    Button { audioPlayer.playPrevious() } label: {
                        Image(systemName: "backward.fill")
                            .font(.title)
                    }
                    .buttonStyle(InteractiveGlassButtonStyle())

                    Button { audioPlayer.togglePlayPause() } label: {
                        Image(systemName: audioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 64))
                    }
                    .buttonStyle(InteractiveGlassButtonStyle())

                    Button { audioPlayer.playNext() } label: {
                        Image(systemName: "forward.fill")
                            .font(.title)
                    }
                    .buttonStyle(InteractiveGlassButtonStyle())
                }
                .foregroundStyle(.primary)
                .glassContainer()

                // Status info
                if !audioPlayer.statusText.isEmpty {
                    HStack(spacing: 6) {
                        if audioPlayer.isBuffering {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Circle()
                                .fill(.green)
                                .frame(width: 8, height: 8)
                        }
                        Text(audioPlayer.statusText)
                            .font(.caption)
                            .foregroundStyle(audioPlayer.isBuffering ? .orange : .secondary)
                    }
                    .padding(.top, 8)
                }

                if let error = audioPlayer.error {
                    VStack(spacing: 8) {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                        if let channel = audioPlayer.currentChannel {
                            Button {
                                audioPlayer.play(channel: channel)
                            } label: {
                                Label("Retry", systemImage: "arrow.clockwise")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(.top, 8)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Now Playing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var channelPlaceholder: some View {
        RoundedRectangle(cornerRadius: 20)
            .fill(.quaternary)
            .frame(width: 200, height: 200)
            .overlay {
                Image(systemName: "radio")
                    .font(.system(size: 60))
                    .foregroundStyle(.secondary)
            }
    }

    private var currentEPG: EPGEntry? {
        guard let channelID = audioPlayer.currentChannel?.epgChannelID else { return nil }
        return providerManager.epgData[channelID]?.first(where: \.isCurrentlyAiring)
    }
}
