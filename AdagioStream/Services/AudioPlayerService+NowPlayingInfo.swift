import MediaPlayer
@preconcurrency import VLCKitSPM

// beads_mobilemusic-t96.14: mechanical split of AudioPlayerService along MARK
// boundaries. Zero behavior change from the pre-split file.
// MPNowPlayingInfoCenter publishing (radio + library track) and
// MPRemoteCommandCenter registration.
extension AudioPlayerService {
    /// Updates `MPNowPlayingInfoCenter` for a track playing in `.library` mode.
    ///
    /// Sets elapsed time, duration, and playback rate so the lock-screen /
    /// Control Center / CarPlay show a live progress bar and a functional
    /// scrubber.  iOS extrapolates the moving position from
    /// `MPNowPlayingInfoPropertyElapsedPlaybackTime` + `PlaybackRate`, so
    /// updates on every timer tick (0.5–3 s) are sufficient — no tight timer needed.
    ///
    /// Called from `startLibraryTrack`, the async artwork fetch, `syncState`
    /// (via the per-mode dispatch at the bottom of the state machine), and
    /// `pause()`.  The radio path continues to call `updateNowPlayingInfo()` unchanged.
    ///
    /// **Elapsed change-detection:**
    /// The `changed` guard is intentionally bypassed for elapsed / rate so that
    /// pause→resume transitions are always flushed even when title / artist
    /// haven't changed.  A rate change from 0.0→1.0 without a matching elapsed
    /// update would freeze the lock-screen scrubber at the paused position.
    internal func updateNowPlayingInfoForTrack() {
        guard let track = currentTrack else { return }

        let title = track.title
        // Artist for the lock screen: the display name threaded in from the album
        // context (via play(track:displayArtistName:via:)).  When none was supplied
        // (e.g. playlist/search playback) we show an empty string rather than the
        // opaque artistId — Track has no denormalised artist name (bug hzl).
        let artist = currentTrackArtistName ?? ""
        let artwork = currentTrackArtwork
        let isLive = false
        // Rate: 1.0 while playing or buffering (iOS interpolates); 0.0 when paused.
        let rate: Double = isPlaying ? 1.0 : 0.0
        let state: MPNowPlayingPlaybackState = (isPlaying || isBuffering) ? .playing : .paused

        // Elapsed time from VLC (milliseconds → seconds).
        // VLCTime.intValue returns -1 when no position is known yet; clamp to 0.
        let vlcTimeMs = mediaPlayer.time.intValue
        let elapsed: Double = vlcTimeMs > 0 ? Double(vlcTimeMs) / 1000.0 : 0.0

        // Duration: prefer VLC's runtime length (available after the stream is
        // parsed), fall back to the static Track.duration from the database.
        let vlcLengthMs = mediaPlayer.media?.length.intValue ?? 0
        let duration: Double? = {
            if vlcLengthMs > 0 { return Double(vlcLengthMs) / 1000.0 }
            if let d = track.duration, d > 0 { return Double(d) }
            return nil
        }()

        // Metadata fields that warrant a full re-publish (title, artist, etc.)
        let metaChanged = title != lastNowPlayingTitle
            || artist != lastNowPlayingArtist
            || isLive != lastNowPlayingIsLive
            || artwork !== lastNowPlayingArtwork

        // Rate / elapsed always re-published on rate change or elapsed drift > 1 s.
        // This ensures pause→resume and seek flush the scrubber immediately.
        let elapsedDrift = abs(elapsed - (lastNowPlayingElapsed ?? -99))
        let rateChanged = rate != lastNowPlayingRate
        let stateChanged = state != lastNowPlayingState
        let needsElapsedUpdate = rateChanged || stateChanged || elapsedDrift > 1.0

        guard metaChanged || needsElapsedUpdate else { return }

        lastNowPlayingTitle = title
        lastNowPlayingArtist = artist
        lastNowPlayingIsLive = isLive
        lastNowPlayingRate = rate
        lastNowPlayingState = state
        lastNowPlayingArtwork = artwork
        lastNowPlayingElapsed = elapsed

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPNowPlayingInfoPropertyIsLiveStream: false,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
        ]
        if let duration {
            info[MPMediaItemPropertyPlaybackDuration] = NSNumber(value: duration)
        }
        if let artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        // d6q.6: Publish elapsed + duration for the in-app seek bar.
        // Only update when the value changed meaningfully (>0.1s drift) to
        // avoid spurious SwiftUI redraws on every timer tick.
        if abs(elapsed - trackElapsed) > 0.1 { trackElapsed = elapsed }
        if trackDuration != duration { trackDuration = duration }

        publishNowPlayingInfo(info, state: state)
        log.log("NowPlaying (track): title=\"\(title)\", artist=\"\(artist)\", isLive=false, state=\(nowPlayingStateName(state)), elapsed=\(String(format: "%.1f", elapsed))s, duration=\(duration.map { String(format: "%.1f", $0) } ?? "nil")s, rate=\(rate)", category: .player)
    }
    // MARK: - Now Playing Info

    public func refreshNowPlayingInfo() {
        // Force a full re-publish, not just an artwork refresh.  Clearing
        // every change-detection field guarantees the next updateNowPlayingInfo
        // writes to MPNowPlayingInfoCenter regardless of whether values
        // appear unchanged — needed because some CarPlay head units only
        // pick up metadata after a fresh write, even if MPNowPlayingInfoCenter
        // already holds the right data (bd 651.1).
        lastNowPlayingTitle = nil
        lastNowPlayingArtist = nil
        lastNowPlayingIsLive = nil
        lastNowPlayingRate = nil
        lastNowPlayingState = nil
        lastNowPlayingArtwork = nil
        lastNowPlayingElapsed = nil
        if currentTrack != nil {
            updateNowPlayingInfoForTrack()
        } else {
            updateNowPlayingInfo()
        }
    }

    internal func updateNowPlayingInfo() {
        guard let channel = currentChannel else { return }

        let title: String
        let artist: String
        let artwork: MPMediaItemArtwork?
        let source: String

        let stillLoading = isBuffering && !isPlaying

        if channelNameOverlayActive {
            // Briefly show the channel name so the user knows which station
            // they switched to (e.g. via steering-wheel controls on CarPlay).
            title = channel.name
            artist = channel.group
            artwork = currentArtwork
            source = "channelNameOverlay"
        } else if let track = sxmService.currentTrack {
            title = track.title
            artist = track.artistDisplay
            artwork = artworkDisplayMode == .coverArt ? (sxmArtwork ?? currentArtwork) : currentArtwork
            source = "sxm"
        } else if let game = ESPNScoreService.shared.gamesByChannel[channel.id] {
            title = game.nowPlayingTitle
            artist = game.nowPlayingSubtitle
            artwork = currentArtwork
            source = "espn"
        } else if let st = streamTitle {
            title = st
            artist = streamArtist ?? channel.name
            artwork = currentArtwork
            source = "streamMetadata"
        } else if let epgID = channel.epgChannelID,
                  let epg = ProviderManager.shared.epgData[epgID]?.first(where: \.isCurrentlyAiring) {
            title = epg.title
            artist = channel.name
            artwork = currentArtwork
            source = "epg"
        } else {
            title = channel.name
            artist = stillLoading ? "Loading..." : channel.group
            artwork = currentArtwork
            source = stillLoading ? "fallback-loading" : "fallback-channel"
        }

        let isLive = !isPlayingBufferedFile
        let rate: Double = (isPlaying || isBuffering) ? 1.0 : 0.0
        let state: MPNowPlayingPlaybackState = (isPlaying || isBuffering) ? .playing : .paused

        // Skip IPC call if nothing changed
        let changed = title != lastNowPlayingTitle
            || artist != lastNowPlayingArtist
            || isLive != lastNowPlayingIsLive
            || rate != lastNowPlayingRate
            || state != lastNowPlayingState
            || artwork !== lastNowPlayingArtwork
        guard changed else { return }

        lastNowPlayingTitle = title
        lastNowPlayingArtist = artist
        lastNowPlayingIsLive = isLive
        lastNowPlayingRate = rate
        lastNowPlayingState = state
        lastNowPlayingArtwork = artwork

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPMediaItemPropertyAlbumTitle: channel.name,
            MPNowPlayingInfoPropertyIsLiveStream: isLive,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
        ]

        if let artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        publishNowPlayingInfo(info, state: state)
        log.log("NowPlaying set: source=\(source), title=\"\(title)\", artist=\"\(artist)\", album=\"\(channel.name)\", isLive=\(isLive), state=\(nowPlayingStateName(state)), rate=\(rate), hasArtwork=\(artwork != nil)", category: .player)
    }

    /// Publishes now-playing info to the system — the tail shared by
    /// `updateNowPlayingInfo` (radio) and `updateNowPlayingInfoForTrack`
    /// (library). Source selection and change-detection differ per caller
    /// and stay inline in each; only the actual publish is common.
    private func publishNowPlayingInfo(_ info: [String: Any], state: MPNowPlayingPlaybackState) {
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = state
    }

    private func nowPlayingStateName(_ state: MPNowPlayingPlaybackState) -> String {
        switch state {
        case .playing: return "playing"
        case .paused: return "paused"
        case .stopped: return "stopped"
        case .interrupted: return "interrupted"
        case .unknown: return "unknown"
        @unknown default: return "raw(\(state.rawValue))"
        }
    }

    internal func fetchSXMArtwork(url: URL, trackID: String) {
        Task {
            guard let image = await ImageCacheService.shared.ephemeralImage(for: url) else { return }
            guard self.sxmService.currentTrack?.id == trackID else { return }
            self.sxmArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.updateNowPlayingInfo()
        }
    }

    internal func fetchArtwork(for channel: Channel) {
        guard let logoURL = channel.logoURL else { return }
        Task {
            guard let image = await ImageCacheService.shared.image(for: logoURL) else { return }
            guard self.currentChannel?.id == channel.id else { return }
            self.currentArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.updateNowPlayingInfo()
        }
    }

    internal func clearNowPlayingInfo() {
        log.log("NowPlaying cleared", category: .player)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        lastNowPlayingTitle = nil
        lastNowPlayingArtist = nil
        lastNowPlayingIsLive = nil
        lastNowPlayingRate = nil
        lastNowPlayingState = nil
        lastNowPlayingArtwork = nil
        lastNowPlayingElapsed = nil
    }

    // MARK: - Remote Commands

    /// Update the enable/disable state of source-dependent remote commands.
    ///
    /// Called whenever `playbackSource` changes (track start, radio start, stop).
    /// Keeps the radio path unchanged and enables the library-specific controls
    /// (scrubber, per-track next/prev) only when in `.library` mode.
    ///
    /// **Why a separate helper instead of inline in `configureRemoteCommands`:**
    /// `configureRemoteCommands` runs once at init and registers handlers.
    /// Enable/disable must respond to runtime source changes — radio vs library —
    /// without re-registering handlers (which would double-fire them).
    internal func updateRemoteCommandsForSource(_ source: PlaybackSource?) {
        let commandCenter = MPRemoteCommandCenter.shared()
        let isLibrary: Bool
        if case .library = source {
            isLibrary = true
        } else {
            isLibrary = false
        }

        // next/prev: enabled for both modes (radio: channel cycling, library: queue nav).
        // Already wired in configureRemoteCommands; ensure enabled state is correct.
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.isEnabled = true

        // Scrubber (changePlaybackPosition): enabled only for finite library tracks.
        // Live radio is seekable=false at the VLC level and must NOT advertise
        // scrubbing — it would confuse the lock-screen and CarPlay UI.
        commandCenter.changePlaybackPositionCommand.isEnabled = isLibrary

        log.log("RemoteCommands updated: isLibrary=\(isLibrary), changePlaybackPosition=\(isLibrary)", category: .remoteCommand)
    }

    internal func configureRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.addTarget { [weak self] _ in
            DebugLogger.shared.log("Remote command: PLAY", category: .remoteCommand)
            Task { @MainActor in self?.resume() }
            return .success
        }

        commandCenter.pauseCommand.addTarget { [weak self] _ in
            DebugLogger.shared.log("Remote command: PAUSE", category: .remoteCommand)
            Task { @MainActor in self?.pause() }
            return .success
        }

        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            DebugLogger.shared.log("Remote command: TOGGLE_PLAY_PAUSE", category: .remoteCommand)
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }

        commandCenter.stopCommand.addTarget { [weak self] _ in
            DebugLogger.shared.log("Remote command: STOP", category: .remoteCommand)
            Task { @MainActor in self?.stop() }
            return .success
        }

        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            DebugLogger.shared.log("Remote command: NEXT_TRACK", category: .remoteCommand)
            Task { @MainActor in
                guard let self else { return }
                // ciu.1: an active audiobook maps next/prev-track to chapter skip
                // (CarPlay now-playing + lock screen both route through here).
                if self.currentAudiobook != nil {
                    self.skipToNextChapter()
                    return
                }
                // d6q.1: route to queue navigation in library mode;
                // retain existing radio channel-cycling otherwise.
                if case .library = self.playbackSource {
                    self.playNextInQueue()
                } else {
                    self.playNext()
                }
            }
            return .success
        }

        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            DebugLogger.shared.log("Remote command: PREVIOUS_TRACK", category: .remoteCommand)
            Task { @MainActor in
                guard let self else { return }
                // ciu.1: an active audiobook maps next/prev-track to chapter skip.
                if self.currentAudiobook != nil {
                    self.skipToPreviousChapter()
                    return
                }
                // d6q.1: route to queue navigation in library mode;
                // retain existing radio channel-cycling otherwise.
                if case .library = self.playbackSource {
                    self.playPreviousInQueue()
                } else {
                    self.playPrevious()
                }
            }
            return .success
        }

        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.skipBackwardCommand.isEnabled = false
        commandCenter.seekForwardCommand.isEnabled = false
        commandCenter.seekBackwardCommand.isEnabled = false

        // Scrubber: enabled dynamically per source via updateRemoteCommandsForSource().
        // Disabled here at init; enabled when a library queue starts.
        commandCenter.changePlaybackPositionCommand.isEnabled = false
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self,
                  let seekEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let positionSeconds = seekEvent.positionTime
            DebugLogger.shared.log("Remote command: CHANGE_PLAYBACK_POSITION pos=\(String(format: "%.1f", positionSeconds))s", category: .remoteCommand)
            Task { @MainActor [weak self] in
                guard let self, case .library = self.playbackSource else { return }
                // VLCTime takes milliseconds as Int32.
                let ms = Int32(exactly: max(0, positionSeconds * 1000).rounded()) ?? Int32(max(0, positionSeconds * 1000))
                self.mediaPlayer.time = VLCTime(int: ms)
                // Force an immediate now-playing update so the lock-screen
                // scrubber snaps to the new position without waiting for the
                // next timer tick.
                self.lastNowPlayingElapsed = nil
                self.updateNowPlayingInfoForTrack()
                self.log.log("Seek via remote command: pos=\(String(format: "%.1f", positionSeconds))s, vlcTimeMs=\(ms)", category: .player)
            }
            return .success
        }
    }
}
