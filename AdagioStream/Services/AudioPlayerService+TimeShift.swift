import AVFoundation
@preconcurrency import VLCKitSPM

// beads_mobilemusic-t96.14: mechanical split of AudioPlayerService along MARK
// boundaries. Zero behavior change from the pre-split file. Time-shift
// buffered playback (playing a captured file while live capture continues).
extension AudioPlayerService {
    // MARK: - Time-Shift Buffered Playback

    internal func playBufferedFile(_ fileURL: URL, for channel: Channel) {
        log.log("playBufferedFile: \(fileURL.lastPathComponent) for \"\(channel.name)\"", category: .player)

        pendingPlayWorkItem?.cancel()
        pendingPlayWorkItem = nil
        interruptedChannel = nil
        interruptedSource = nil        // d6q.8
        interruptedQueueAPI = nil      // d6q.8
        interruptedElapsedSeconds = nil // d6q.8
        lastLoggedVLCState = nil
        stateTimer?.invalidate()

        // Destroy old player — always pass caching options to avoid
        // poisoning VLCKit's shared VLCLibrary with option-less defaults.
        let hadActiveMedia = mediaPlayer.media != nil || isActiveSession
        if hadActiveMedia {
            let cacheMs = Int(bufferDuration * 1000)
            retirePlayer(options: [
                "--network-caching=\(cacheMs)",
                "--live-caching=\(cacheMs)",
            ])
        }

        currentChannel = channel
        playbackSource = .radio(channel)   // d6q.7: mirror into PlaybackSource seam
        isPlayingBufferedFile = true
        bufferedChannel = channel
        currentBufferFileURL = fileURL
        bufferPlaybackStartedAt = Date()
        isActiveSession = false
        isBuffering = true
        isPlaying = false
        error = nil

        let media = VLCMedia(url: fileURL)
        media.delegate = self
        mediaPlayer.media = media
        mediaPlayer.audio?.volume = 100
        mediaPlayer.play()
        isActiveSession = true

        log.log("Buffered playback started, starting continuation capture", category: .player)

        // Start capturing the live stream into a new file while we play
        // the old buffer — this chains seamlessly when the buffer ends.
        timeShiftBuffer.startCapture(for: channel, estimatedBitrateKbps: streamBitrateKbps)

        currentPollInterval = fastPollInterval
        startStateTimer(interval: fastPollInterval)
    }

    /// Skip buffered content and rejoin the live stream immediately.
    public func skipToLive() {
        log.log("skipToLive: isPlayingBuffer=\(isPlayingBufferedFile)", category: .player)
        guard isPlayingBufferedFile || timeShiftBuffer.isTimeShifted,
              let channel = bufferedChannel ?? currentChannel else { return }

        if let oldURL = currentBufferFileURL {
            timeShiftBuffer.deleteBufferFile(at: oldURL)
            currentBufferFileURL = nil
        }
        isPlayingBufferedFile = false
        bufferedChannel = nil
        timeShiftBuffer.goLive()
        play(channel: channel)
    }
}
