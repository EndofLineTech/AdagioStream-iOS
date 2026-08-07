@preconcurrency import VLCKitSPM
#if os(iOS)
import UIKit
#endif

// beads_mobilemusic-t96.14: mechanical split of AudioPlayerService along MARK
// boundaries. Zero behavior change from the pre-split file.
// VLCMediaPlayerDelegate / VLCMediaDelegate conformances.
extension AudioPlayerService {
    // MARK: - VLCMediaPlayerDelegate

    public nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        Task { @MainActor in
            let newState = self.mediaPlayer.state
            let oldState = self.lastLoggedVLCState

            // Only log on actual state transitions to avoid flooding
            if newState != oldState {
                self.lastLoggedVLCState = newState
                self.logVLCTransition(from: oldState, to: newState)
            }
            self.syncState()

            // bug w6n: MobileVLCKit disables the idle timer internally on
            // play (it's built for video playback) and doesn't reliably
            // restore it for audio-only streams, since no drawable is ever
            // attached here — audio routes through an amem callback into
            // AVAudioEngine. This app is audio-only, so re-assert on every
            // VLC state change that the idle timer stays enabled.
            #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = false
            #endif
        }
    }

    private func logVLCTransition(from oldState: VLCMediaPlayerState?, to newState: VLCMediaPlayerState) {
        let oldName = oldState.map { vlcStateName($0) } ?? "nil"
        let newName = vlcStateName(newState)
        let isPlaying = mediaPlayer.isPlaying
        let willPlay = mediaPlayer.willPlay

        var details = "VLC STATE: \(oldName) → \(newName), isPlaying=\(isPlaying), willPlay=\(willPlay)"

        // Add media-level diagnostics
        if let media = mediaPlayer.media {
            let mediaState = media.state
            let parsed = media.parsedStatus
            let mediaStateName: String
            switch mediaState {
            case .nothingSpecial: mediaStateName = "nothingSpecial"
            case .buffering: mediaStateName = "buffering"
            case .playing: mediaStateName = "playing"
            case .error: mediaStateName = "ERROR"
            @unknown default: mediaStateName = "unknown(\(mediaState.rawValue))"
            }

            let parsedName: String
            switch parsed.rawValue {
            case 0: parsedName = "init"
            case 1: parsedName = "skipped"
            case 2: parsedName = "FAILED"
            case 3: parsedName = "TIMEOUT"
            case 4: parsedName = "done"
            default: parsedName = "unknown(\(parsed.rawValue))"
            }

            details += ", media=\(mediaStateName), parsed=\(parsedName)"

            // Stats snapshot
            let stats = media.statistics
            details += ", in=\(stats.readBytes)B@\(String(format: "%.1f", stats.inputBitrate * 1000))kbps"
            details += ", demux=\(stats.demuxReadBytes)B@\(String(format: "%.1f", stats.demuxBitrate * 1000))kbps"
            if stats.demuxCorrupted > 0 { details += ", corrupted=\(stats.demuxCorrupted)" }
            if stats.demuxDiscontinuity > 0 { details += ", discontinuity=\(stats.demuxDiscontinuity)" }
            details += ", decoded(a=\(stats.decodedAudio),v=\(stats.decodedVideo))"
            if stats.lostAudioBuffers > 0 { details += ", lostAudio=\(stats.lostAudioBuffers)" }

            // Track info
            let tracks = media.tracksInformation as? [[String: Any]] ?? []
            let audioTracks = tracks.filter { ($0["type"] as? String) == "audio" }
            let videoTracks = tracks.filter { ($0["type"] as? String) == "video" }
            details += ", tracks(a=\(audioTracks.count),v=\(videoTracks.count))"
        } else {
            details += ", media=NIL"
        }

        // amem pipeline diagnostics:
        //   play / lastCount = total play_cb calls / last frame count
        //     (lastCount validates "frames per channel" interpretation:
        //      typical 1024–2048; combined with total/elapsed gives
        //      empirical sample rate)
        //   totalFrames = sum of frame counts (≈ sampleRate * playSeconds)
        //   buf / dropped = current ring depth / overflow count
        //   render / under = AVAudioEngine render-block calls /
        //     calls that had to zero-fill (engine starvation)
        details += ", amem(play=\(VLCAudioCallbackBridge.playCallbackCount),lastCnt=\(VLCAudioCallbackBridge.lastPlayCallbackCount),total=\(VLCAudioCallbackBridge.totalReceivedFrames),pts=\(VLCAudioCallbackBridge.lastPlayCallbackPTS),buf=\(VLCAudioCallbackBridge.bufferedFrames),dropped=\(VLCAudioCallbackBridge.droppedFrameCount),render=\(VLCAudioCallbackBridge.renderCallCount),under=\(VLCAudioCallbackBridge.renderUnderrunCount))"

        log.log(details, category: .vlcState)
    }

    internal func vlcStateName(_ state: VLCMediaPlayerState) -> String {
        switch state {
        case .stopped: return "stopped"
        case .opening: return "opening"
        case .buffering: return "buffering"
        case .ended: return "ended"
        case .error: return "ERROR"
        case .playing: return "playing"
        case .paused: return "paused"
        case .esAdded: return "esAdded"
        @unknown default: return "unknown(\(state.rawValue))"
        }
    }

    // MARK: - VLCMediaDelegate

    public nonisolated func mediaDidFinishParsing(_ aMedia: VLCMedia) {
        Task { @MainActor in
            let parsed = aMedia.parsedStatus
            let parsedName: String
            switch parsed.rawValue {
            case 0: parsedName = "init"
            case 1: parsedName = "skipped"
            case 2: parsedName = "FAILED"
            case 3: parsedName = "TIMEOUT"
            case 4: parsedName = "done"
            default: parsedName = "unknown(\(parsed.rawValue))"
            }
            let tracks = aMedia.tracksInformation as? [[String: Any]] ?? []
            DebugLogger.shared.log("Media parsed: status=\(parsedName), tracks=\(tracks.count), url=\(aMedia.url?.redactedForLog ?? "nil")", category: .vlcState)
            if parsed.rawValue == 2 || parsed.rawValue == 3 { // failed or timeout
                DebugLogger.shared.log("MEDIA PARSE FAILURE: This may explain why playback didn't start", category: .vlcState)
            }
        }
    }

    public nonisolated func mediaMetaDataDidChange(_ aMedia: VLCMedia) {
        let meta = aMedia.metaData
        let nowPlaying = meta.nowPlaying
        let metaTitle = meta.title
        let metaArtist = meta.artist

        DebugLogger.shared.log("Media metadata changed: nowPlaying=\(nowPlaying ?? "nil"), title=\(metaTitle ?? "nil"), artist=\(metaArtist ?? "nil")", category: .vlcState)

        Task { @MainActor [weak self] in
            guard let self else { return }
            var title: String?
            var artist: String?

            if let nowPlaying, !nowPlaying.isEmpty {
                // ICY streams typically send "Artist - Title"
                let parts = nowPlaying.components(separatedBy: " - ")
                if parts.count >= 2 {
                    artist = parts[0].trimmingCharacters(in: .whitespaces)
                    title = parts.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces)
                } else {
                    title = nowPlaying
                }
            }

            // ID3 tags take precedence if available. VLC reports the URL's last
            // path component as the title for raw TS streams with no embedded
            // tags — that's a filename, not metadata (cxa).
            if let metaTitle, !metaTitle.isEmpty,
               metaTitle != self.currentChannel?.name,
               metaTitle != aMedia.url?.lastPathComponent {
                title = metaTitle
            }
            if let metaArtist, !metaArtist.isEmpty {
                artist = metaArtist
            }

            let changed = title != self.streamTitle || artist != self.streamArtist
            guard changed else { return }
            self.streamTitle = title
            self.streamArtist = artist
            self.updateNowPlayingInfo()
        }
    }

}
