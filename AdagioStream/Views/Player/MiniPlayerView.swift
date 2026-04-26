import AdagioStreamCore
import SwiftUI

struct MiniPlayerView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @EnvironmentObject var sxmService: SXMMetadataService
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showNowPlaying = false

    private var logoSize: CGFloat { sizeClass == .regular ? 44 : 36 }
    private var logoRadius: CGFloat { sizeClass == .regular ? 8 : 6 }
    private var buttonSize: CGFloat { sizeClass == .regular ? 48 : 44 }

    var body: some View {
        HStack(spacing: 12) {
            // Channel logo + info — tapping opens full player
            Button {
                showNowPlaying = true
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        if settingsViewModel.settings.artworkDisplayMode == .coverArt,
                           let track = sxmService.currentTrack, let artworkURL = track.artworkURL {
                            RetryableAsyncImage(url: artworkURL, width: logoSize, height: logoSize, cornerRadius: logoRadius, persistent: false)
                        } else if let logoURL = audioPlayer.currentChannel?.logoURL {
                            RetryableAsyncImage(url: logoURL, width: logoSize, height: logoSize, cornerRadius: logoRadius)
                        } else {
                            Image(systemName: "radio")
                                .frame(width: logoSize, height: logoSize)
                                .foregroundStyle(.secondary)
                        }

                        if audioPlayer.isBuffering {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(.ultraThinMaterial)
                                .frame(width: logoSize, height: logoSize)
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(audioPlayer.currentChannel?.name ?? "")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        if let track = sxmService.currentTrack {
                            Text("\(track.artistDisplay) — \(track.title)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else if let game = audioPlayer.currentChannel.flatMap({ ESPNScoreService.shared.gamesByChannel[$0.id] }) {
                            Text(game.displayText)
                                .font(.caption)
                                .foregroundStyle(game.state == .live ? .primary : .secondary)
                                .lineLimit(1)
                        } else if let streamTitle = audioPlayer.streamTitle {
                            Text("\(audioPlayer.streamArtist.map { "\($0) — " } ?? "")\(streamTitle)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else if let error = audioPlayer.error {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .lineLimit(1)
                        } else if audioPlayer.timeShiftBuffer.isTimeShifted {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(.orange)
                                    .frame(width: 6, height: 6)
                                Text(audioPlayer.statusText)
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .lineLimit(1)
                                Button {
                                    audioPlayer.skipToLive()
                                } label: {
                                    Text("LIVE")
                                        .font(.caption2.bold())
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(.red))
                                }
                                .buttonStyle(.plain)
                            }
                        } else if !audioPlayer.statusText.isEmpty {
                            HStack(spacing: 4) {
                                Text(audioPlayer.statusText)
                                    .font(.caption)
                                    .foregroundStyle(audioPlayer.isBuffering ? .orange : .secondary)
                                if let start = audioPlayer.listeningStartDate {
                                    HStack(spacing: 0) {
                                        Text("\u{00B7} ")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(start.addingTimeInterval(-audioPlayer.accumulatedListeningTime), style: .timer)
                                            .font(.caption)
                                            .monospacedDigit()
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
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
                    .frame(width: buttonSize, height: buttonSize)
            }
            .buttonStyle(.plain)

            // Stop button
            Button {
                audioPlayer.stop()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: buttonSize, height: buttonSize)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .hoverEffect(.highlight)
        .glassBackground()
        .glassContainer()
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

}
