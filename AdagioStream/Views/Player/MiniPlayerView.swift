import SwiftUI

struct MiniPlayerView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @EnvironmentObject var sxmService: SXMMetadataService
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showNowPlaying = false
    @AppStorage(SXMSportsPriority.defaultsKey) private var preferScores = true

    private var logoSize: CGFloat { sizeClass == .regular ? 44 : 36 }
    private var logoRadius: CGFloat { sizeClass == .regular ? 8 : 6 }
    private var buttonSize: CGFloat { sizeClass == .regular ? 48 : 44 }

    var body: some View {
        HStack(spacing: 12) {
            // Item artwork + info — tapping opens full player
            Button {
                showNowPlaying = true
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        // d6q.2: for library tracks, render artwork from nowPlaying.artworkURL
                        // (populated by the track's cover-art fetch in play(track:via:)).
                        // For radio, keep existing SXM cover-art → channel logo priority.
                        if audioPlayer.currentAudiobook != nil, let artworkURL = audioPlayer.nowPlayingArtworkURL {
                            // yu8.4: audiobook cover.
                            RetryableAsyncImage(url: artworkURL, width: logoSize, height: logoSize, cornerRadius: logoRadius, persistent: true)
                        } else if audioPlayer.currentAudiobook != nil {
                            Image(systemName: "book.closed")
                                .frame(width: logoSize, height: logoSize)
                                .foregroundStyle(.secondary)
                        } else if let item = audioPlayer.nowPlaying, !item.isLiveStream,
                           let artworkURL = audioPlayer.nowPlayingArtworkURL {
                            RetryableAsyncImage(url: artworkURL, width: logoSize, height: logoSize, cornerRadius: logoRadius, persistent: false)
                        } else if settingsViewModel.settings.artworkDisplayMode == .coverArt,
                           let track = sxmService.currentTrack, let artworkURL = track.artworkURL {
                            RetryableAsyncImage(url: artworkURL, width: logoSize, height: logoSize, cornerRadius: logoRadius, persistent: false)
                        } else if let logoURL = audioPlayer.currentChannel?.logoURL {
                            RetryableAsyncImage(url: logoURL, width: logoSize, height: logoSize, cornerRadius: logoRadius)
                        } else {
                            Image(systemName: audioPlayer.nowPlaying?.isLiveStream == false ? "music.note" : "radio")
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
                        // yu8.4: audiobook — chapter title primary, book title secondary.
                        if let book = audioPlayer.currentAudiobook {
                            Text(audioPlayer.currentChapter?.title ?? book.title)
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .lineLimit(1)
                            Text(book.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else {
                        // d6q.2: use nowPlaying.displayTitle for both radio and library.
                        Text(audioPlayer.nowPlaying?.displayTitle ?? "")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        // Library track: show the threaded artist name (bug hzl).
                        if let item = audioPlayer.nowPlaying, !item.isLiveStream {
                            if let subtitle = audioPlayer.nowPlayingSubtitle, !subtitle.isEmpty {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        } else if let track = sxmService.currentTrack,
                                  !(preferScores && audioPlayer.currentChannel.flatMap({ ESPNScoreService.shared.gamesByChannel[$0.id] }) != nil) {
                            // Radio: SXM now-playing metadata (yields to a live game when preferScores)
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
                        } // end non-audiobook branch
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
            .accessibilityLabel(audioPlayer.isPlaying ? "Pause" : "Play")

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
            .accessibilityLabel("Stop")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .hoverEffect(.highlight)
        .glassBackground()
        .glassContainer()
        // d6q.6: 2pt determinate progress hairline for library tracks only.
        // Radio mini-player is unchanged (isLiveStream == true, so no hairline).
        .overlay(alignment: .bottom) {
            if let item = audioPlayer.nowPlaying, !item.isLiveStream,
               let duration = audioPlayer.trackDuration, duration > 0 {
                GeometryReader { geo in
                    let fraction = min(1.0, max(0.0, audioPlayer.trackElapsed / duration))
                    Rectangle()
                        .fill(.tint.opacity(0.7))
                        .frame(width: geo.size.width * fraction, height: 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 2)
                .accessibilityHidden(true)
            }
        }
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

}
