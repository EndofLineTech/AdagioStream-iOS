import SwiftUI

struct NowPlayingView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @EnvironmentObject var providerManager: ProviderManager
    @EnvironmentObject var sxmService: SXMMetadataService
    @EnvironmentObject var savedSongsManager: SavedSongsManager
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass

    // d6q.6: seek bar scrub state — local @State so the slider doesn't fight the 0.5s timer
    @State private var scrubValue: Double = 0.0
    @State private var isScrubbing: Bool = false
    // d6q.6: up-next queue sheet
    @State private var showUpNext: Bool = false

    private var artworkSize: CGFloat { sizeClass == .regular ? 300 : 200 }
    private var artworkRadius: CGFloat { sizeClass == .regular ? 24 : 20 }
    private var playButtonSize: CGFloat { sizeClass == .regular ? 80 : 64 }
    private var controlSpacing: CGFloat { sizeClass == .regular ? 56 : 40 }

    /// True when a library (non-live-stream) track is playing.
    private var isLibraryMode: Bool {
        if let item = audioPlayer.nowPlaying { return !item.isLiveStream }
        return false
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                // Artwork — d6q.2: library tracks render from nowPlaying.artworkURL;
                // radio keeps the existing SXM cover-art → channel-logo priority.
                if let item = audioPlayer.nowPlaying, !item.isLiveStream,
                   let artworkURL = item.artworkURL {
                    RetryableAsyncImage(url: artworkURL, width: artworkSize, height: artworkSize, cornerRadius: artworkRadius, persistent: false)
                        .shadow(radius: 10)
                        .id(item.displayTitle)
                } else if settingsViewModel.settings.artworkDisplayMode == .coverArt,
                   let track = sxmService.currentTrack, let artworkURL = track.artworkURL {
                    RetryableAsyncImage(url: artworkURL, width: artworkSize, height: artworkSize, cornerRadius: artworkRadius, persistent: false)
                        .shadow(radius: 10)
                        .id(track.id)
                } else if let logoURL = audioPlayer.currentChannel?.logoURL {
                    RetryableAsyncImage(url: logoURL, width: artworkSize, height: artworkSize, cornerRadius: artworkRadius)
                        .shadow(radius: 10)
                        .id(audioPlayer.currentChannel?.id)
                } else {
                    channelPlaceholder
                }

                // Track / channel info
                VStack(spacing: 8) {
                    // d6q.2: library mode — show track title as primary, subtitle as secondary.
                    if let item = audioPlayer.nowPlaying, !item.isLiveStream {
                        Text(item.displayTitle)
                            .font(.title2)
                            .fontWeight(.bold)
                            .multilineTextAlignment(.center)
                        if let subtitle = item.displaySubtitle {
                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        // Radio mode — unchanged behaviour.
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
                }

                // d6q.6: Seek bar — library only; radio keeps the LIVE status (no seek bar)
                if isLibraryMode {
                    librarySeekBar
                }

                // Playback controls
                if isLibraryMode {
                    libraryTransportControls
                } else {
                    radioTransportControls
                }

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
                        .accessibilityLabel(savedSongsManager.isSaved(trackID: track.id) ? "Remove from Loved" : "Add to Loved")
                        .accessibilityValue(savedSongsManager.isSaved(trackID: track.id) ? "Loved" : "Not loved")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        // d6q.6: Up Next button — library only
                        if isLibraryMode && !audioPlayer.currentLibraryQueue.isEmpty {
                            Button {
                                showUpNext = true
                            } label: {
                                Image(systemName: "list.bullet")
                                    .accessibilityLabel("Up Next")
                            }
                        }
                        AirPlayRoutePickerView()
                            .frame(width: 24, height: 24)
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
        // d6q.6: Up-next queue sheet
        .sheet(isPresented: $showUpNext) {
            UpNextView()
        }
        // d6q.6: keep scrubValue in sync with trackElapsed while not scrubbing
        .onChange(of: audioPlayer.trackElapsed) { _, newElapsed in
            if !isScrubbing { scrubValue = newElapsed }
        }
        // Self-dismiss when playback ends (user stop, or CarPlay disconnect
        // calling stop()). The presenting MiniPlayerView is removed from the
        // hierarchy at the same moment, which would otherwise orphan this sheet
        // and leave the "play interface" up on the phone (bd tpu).
        // d6q.2: for library tracks, currentChannel is intentionally nil, so
        // the original "dismiss on channel=nil" logic would fire incorrectly.
        // Instead observe isActiveSession via isPlaying+isBuffering: after stop()
        // both are false AND nowPlayingActive becomes false.
        .onChange(of: audioPlayer.currentChannel?.id) { _, newID in
            // Radio: dismiss when channel clears (stop() or CarPlay disconnect).
            if newID == nil && !audioPlayer.isPlaying && !audioPlayer.isBuffering {
                dismiss()
            }
        }
        .onChange(of: audioPlayer.isPlaying) { _, _ in
            // Library: dismiss when stopped (isPlaying=false, isBuffering=false,
            // and no channel or track is set).
            if !audioPlayer.isPlaying && !audioPlayer.isBuffering
                && audioPlayer.currentChannel == nil
                && audioPlayer.nowPlaying == nil {
                dismiss()
            }
        }
    }

    // MARK: - d6q.6: Library seek bar

    @ViewBuilder
    private var librarySeekBar: some View {
        let duration = audioPlayer.trackDuration ?? 1.0
        let displayElapsed = isScrubbing ? scrubValue : audioPlayer.trackElapsed

        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubValue : audioPlayer.trackElapsed },
                    set: { newVal in
                        scrubValue = newVal
                        isScrubbing = true
                    }
                ),
                in: 0...max(duration, 1.0)
            ) {
                Text("Playback position")
            } minimumValueLabel: {
                Text(formatTime(displayElapsed))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text(audioPlayer.trackDuration.map(formatTime) ?? "--:--")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } onEditingChanged: { editing in
                isScrubbing = editing
                if !editing {
                    // Commit seek on drag release
                    audioPlayer.seek(to: scrubValue)
                }
            }
            .accessibilityLabel("Seek")
            .accessibilityValue("\(Int(displayElapsed)) of \(Int(duration)) seconds")
            .accessibilityAdjustableAction { direction in
                let step: Double = 10.0
                switch direction {
                case .increment: audioPlayer.seek(to: min(audioPlayer.trackElapsed + step, duration))
                case .decrement: audioPlayer.seek(to: max(audioPlayer.trackElapsed - step, 0))
                @unknown default: break
                }
            }
        }
        .padding(.horizontal)
    }

    // MARK: - d6q.6: Library transport controls (prev/play-pause/next + shuffle + repeat)

    @ViewBuilder
    private var libraryTransportControls: some View {
        VStack(spacing: 20) {
            // Main transport row
            HStack(spacing: controlSpacing) {
                Button {
                    audioPlayer.playPreviousInQueue()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.title)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Previous track")

                Button {
                    audioPlayer.togglePlayPause()
                } label: {
                    Image(systemName: audioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: playButtonSize))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(audioPlayer.isPlaying ? "Pause" : "Play")

                Button {
                    audioPlayer.playNextInQueue()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.title)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Next track")
            }
            .foregroundStyle(.primary)
            .glassContainer()

            // Shuffle + Repeat row
            HStack(spacing: 40) {
                shuffleButton
                repeatButton
            }
        }
    }

    // MARK: - Radio transport controls (unchanged from pre-d6q.6)

    @ViewBuilder
    private var radioTransportControls: some View {
        HStack(spacing: controlSpacing) {
            Button { audioPlayer.playPrevious() } label: {
                Image(systemName: "backward.fill")
                    .font(.title)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Previous channel")

            Button { audioPlayer.togglePlayPause() } label: {
                Image(systemName: audioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: playButtonSize))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(audioPlayer.isPlaying ? "Pause" : "Play")

            Button { audioPlayer.playNext() } label: {
                Image(systemName: "forward.fill")
                    .font(.title)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Next channel")
        }
        .foregroundStyle(.primary)
        .glassContainer()
    }

    // MARK: - Shuffle button

    @ViewBuilder
    private var shuffleButton: some View {
        let isOn = audioPlayer.shuffleEnabled
        Button {
            audioPlayer.toggleShuffle()
        } label: {
            Image(systemName: "shuffle")
                .font(.title2)
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Shuffle")
        .accessibilityValue(isOn ? "on" : "off")
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    // MARK: - Repeat button

    @ViewBuilder
    private var repeatButton: some View {
        let mode = audioPlayer.repeatMode
        let isActive = mode != .off
        Button {
            audioPlayer.cycleRepeatMode()
        } label: {
            Image(systemName: repeatIconName(for: mode))
                .font(.title2)
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Repeat")
        .accessibilityValue(repeatAccessibilityValue(for: mode))
    }

    // MARK: - Helpers

    private func repeatIconName(for mode: RepeatMode) -> String {
        switch mode {
        case .off:  return "repeat"
        case .all:  return "repeat"
        case .one:  return "repeat.1"
        }
    }

    private func repeatAccessibilityValue(for mode: RepeatMode) -> String {
        switch mode {
        case .off:  return "off"
        case .all:  return "all"
        case .one:  return "one"
        }
    }

    /// Formats a time interval as mm:ss.
    private func formatTime(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private var channelPlaceholder: some View {
        RoundedRectangle(cornerRadius: artworkRadius)
            .fill(.quaternary)
            .frame(width: artworkSize, height: artworkSize)
            .overlay {
                Image(systemName: "radio")
                    .font(.system(size: artworkSize * 0.3))
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

// MARK: - d6q.6: Up-next queue view

struct UpNextView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            let queue = audioPlayer.currentLibraryQueue
            let currentIndex = audioPlayer.currentQueueIndex ?? 0

            List {
                if queue.isEmpty {
                    Text("Queue is empty")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(queue.enumerated()), id: \.element.id) { offset, track in
                        queueRow(track: track, index: offset, currentIndex: currentIndex)
                    }
                    .onMove { source, destination in
                        // List's onMove delivers indices relative to the section;
                        // translate to a single-item move (ForEach linearises the list).
                        guard let sourceIndex = source.first else { return }
                        // SwiftUI List delivers `destination` as the insertion index,
                        // which equals the final position when moving forward, or the
                        // position before the target row when moving backward.
                        // Adjust to match the "after remove, before insert" semantics
                        // used by moveQueueItem: destination > source means the item
                        // will land one position earlier in the final array, so subtract 1.
                        let dest = destination > sourceIndex ? destination - 1 : destination
                        audioPlayer.moveQueueItem(from: sourceIndex, to: dest)
                    }
                }
            }
            .navigationTitle("Up Next")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }
            }
        }
    }

    @ViewBuilder
    private func queueRow(track: Track, index: Int, currentIndex: Int) -> some View {
        let isPlaying = index == currentIndex
        Button {
            if !isPlaying {
                audioPlayer.playQueueItem(at: index)
            }
        } label: {
            HStack(spacing: 12) {
                // Playing indicator
                if isPlaying {
                    Image(systemName: audioPlayer.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 16)
                        .accessibilityHidden(true)
                } else {
                    Text("\(index + 1)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                        .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.body)
                        .fontWeight(isPlaying ? .semibold : .regular)
                        .foregroundStyle(isPlaying ? Color.accentColor : Color.primary)
                        .lineLimit(1)
                    if let subtitle = track.displaySubtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if let duration = track.duration {
                    Text(formatTime(Double(duration)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(track.title)\(isPlaying ? ", now playing" : ", track \(index + 1)")")
        .accessibilityHint(isPlaying ? "" : "Double tap to jump to this track")
    }

    private func formatTime(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
