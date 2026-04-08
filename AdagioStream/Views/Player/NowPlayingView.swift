import SwiftUI

struct NowPlayingView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @EnvironmentObject var providerManager: ProviderManager
    @EnvironmentObject var sxmService: SXMMetadataService
    @EnvironmentObject var savedSongsManager: SavedSongsManager
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                // Artwork
                if settingsViewModel.settings.artworkDisplayMode == .coverArt,
                   let track = sxmService.currentTrack, let artworkURL = track.artworkURL {
                    RetryableAsyncImage(url: artworkURL, width: 200, height: 200, cornerRadius: 20, persistent: false)
                        .shadow(radius: 10)
                        .id(track.id)
                } else if let logoURL = audioPlayer.currentChannel?.logoURL {
                    RetryableAsyncImage(url: logoURL, width: 200, height: 200, cornerRadius: 20)
                        .shadow(radius: 10)
                        .id(audioPlayer.currentChannel?.id)
                } else {
                    channelPlaceholder
                }

                // Channel / track info
                VStack(spacing: 8) {
                    Text(audioPlayer.currentChannel?.name ?? "Not Playing")
                        .font(.title2)
                        .fontWeight(.bold)
                        .multilineTextAlignment(.center)

                    if let track = sxmService.currentTrack {
                        Text(track.title)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                        Text(track.artistDisplay)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else if let game = currentGame {
                        Text(game.nowPlayingTitle)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                        Text(game.nowPlayingSubtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else if let streamTitle = audioPlayer.streamTitle {
                        Text(streamTitle)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                        if let streamArtist = audioPlayer.streamArtist {
                            Text(streamArtist)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } else {
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
                }

                // Playback controls
                HStack(spacing: 40) {
                    Button { audioPlayer.playPrevious() } label: {
                        Image(systemName: "backward.fill")
                            .font(.title)
                    }
                    .buttonStyle(.plain)

                    Button { audioPlayer.togglePlayPause() } label: {
                        Image(systemName: audioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 64))
                    }
                    .buttonStyle(.plain)

                    Button { audioPlayer.playNext() } label: {
                        Image(systemName: "forward.fill")
                            .font(.title)
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(.primary)
                .glassContainer()

                // Status info
                if audioPlayer.timeShiftBuffer.isTimeShifted {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(.orange)
                            .frame(width: 8, height: 8)
                        Text(audioPlayer.statusText)
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button {
                            audioPlayer.skipToLive()
                        } label: {
                            Text("LIVE")
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(.red))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 8)
                } else if !audioPlayer.statusText.isEmpty {
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

                // Listening timer
                if let start = audioPlayer.listeningStartDate {
                    Text(start.addingTimeInterval(-audioPlayer.accumulatedListeningTime), style: .timer)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
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
                if let track = sxmService.currentTrack {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            savedSongsManager.toggleSave(track: track, channel: audioPlayer.currentChannel)
                        } label: {
                            Image(systemName: savedSongsManager.isSaved(trackID: track.id) ? "heart.fill" : "heart")
                                .foregroundStyle(savedSongsManager.isSaved(trackID: track.id) ? .red : .secondary)
                        }
                    }
                }
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

    private var currentGame: ESPNGameInfo? {
        guard let channelID = audioPlayer.currentChannel?.id else { return nil }
        return ESPNScoreService.shared.gamesByChannel[channelID]
    }

    private var currentEPG: EPGEntry? {
        guard let channelID = audioPlayer.currentChannel?.epgChannelID else { return nil }
        return providerManager.epgData[channelID]?.first(where: \.isCurrentlyAiring)
    }
}
