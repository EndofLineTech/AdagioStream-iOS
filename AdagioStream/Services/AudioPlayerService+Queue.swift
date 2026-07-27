import AVFoundation
import MediaPlayer
@preconcurrency import VLCKitSPM

// beads_mobilemusic-t96.14: mechanical split of AudioPlayerService along MARK
// boundaries. Zero behavior change from the pre-split file. Library queue
// state, shuffle/repeat, auto-advance, seek, queue reorder, and scrobble
// forwarding.
extension AudioPlayerService {
    // MARK: - Track playback (d6q.2) + Queue API (d6q.1)

    /// Plays a single on-demand track from the Navidrome library.
    ///
    /// Thin wrapper over `setQueue(_:startIndex:displayArtistName:via:)` that
    /// creates a one-track queue.  Kept as a convenience entry-point so all
    /// existing call sites continue to compile unchanged.
    ///
    /// Radio playback is unaffected: `play(channel:)` remains the sole entry
    /// point for live streams.
    ///
    /// - Parameters:
    ///   - track: The `Track` to play.
    ///   - displayArtistName: Human-readable artist name from the album context.
    ///     When provided, shown as the now-playing / mini-player subtitle.
    ///     Pass `nil` for no subtitle (Track has no denormalised artist name).
    ///   - api: A configured `NavidromeAPI` instance for URL building.
    public func play(track: Track, displayArtistName: String? = nil, via api: NavidromeAPI) {
        setQueue([track], startIndex: 0, displayArtistName: displayArtistName, via: api)
    }

    // MARK: Queue API (d6q.1)

    /// Sets the playback queue and starts playing at the given index.
    ///
    /// This is the single authoritative entry-point for library playback.
    /// Both `play(track:)` and the browse-UI enqueue calls route through here.
    ///
    /// **Edge rules (documented):**
    /// - Out-of-bounds `startIndex` is clamped to `0..<tracks.count`; if
    ///   `tracks` is empty the call is a no-op (logs and returns).
    /// - `playNextInQueue()` at the last index (no repeat mode): stops playback.
    /// - `playPreviousInQueue()` at index 0: restarts the current track.
    ///
    /// **displayArtistName threading:**
    /// The supplied `displayArtistName` is stored as `queueDisplayArtistName`
    /// and applies to every track in the queue (e.g. the album artist for an
    /// album queue).  `updateNowPlayingInfoForTrack()` uses this value as the
    /// subtitle for each track unless the track itself later exposes its own
    /// artist name.
    ///
    /// - Parameters:
    ///   - tracks: The ordered list of tracks that constitute the queue.
    ///   - startIndex: The index of the track to begin playing.  Clamped to
    ///     valid bounds if out of range.
    ///   - displayArtistName: Queue-level display artist (e.g. album artist).
    ///     Carried forward on every next/previous advance within this queue.
    ///   - api: `NavidromeAPI` retained for URL building during queue navigation.
    public func setQueue(
        _ tracks: [Track],
        startIndex: Int,
        displayArtistName: String? = nil,
        via api: NavidromeAPI
    ) {
        guard !tracks.isEmpty else {
            log.log("setQueue: called with empty track list — no-op", category: .player)
            return
        }

        let clampedIndex = max(0, min(startIndex, tracks.count - 1))
        if clampedIndex != startIndex {
            log.log("setQueue: startIndex=\(startIndex) out of bounds for \(tracks.count) tracks — clamped to \(clampedIndex)", category: .player)
        }

        log.log("setQueue: \(tracks.count) tracks, startIndex=\(clampedIndex), artist=\"\(displayArtistName ?? "nil")\", shuffle=\(shuffleEnabled)", category: .player)

        // Store queue-level state before calling the internal player setup.
        queueDisplayArtistName = displayArtistName
        queueAPI = api
        currentQueueIndex = clampedIndex

        // (Re-)build the shuffle order for the new queue when shuffle is on.
        // The start track is pinned to position 0; the rest are randomised.
        if shuffleEnabled {
            shuffleOrder = buildShuffleOrder(queueCount: tracks.count, pinning: clampedIndex)
            shufflePosition = 0
        } else {
            shuffleOrder = []
            shufflePosition = 0
        }

        let track = tracks[clampedIndex]
        startLibraryTrack(track, inQueue: tracks, at: clampedIndex, via: api)
    }

    // MARK: - Shuffle helpers (d6q.4)

    /// Builds a shuffle permutation for `queueCount` tracks with `pinned`
    /// fixed at position 0 (so the current track is first in the play order).
    private func buildShuffleOrder(queueCount: Int, pinning pinnedIndex: Int) -> [Int] {
        var rest = Array(0..<queueCount).filter { $0 != pinnedIndex }
        rest.shuffle()
        return [pinnedIndex] + rest
    }

    /// Builds a full shuffle permutation for `queueCount` tracks with no
    /// position pinned (used on repeat-all wrap).
    private func buildShuffleOrderFull(queueCount: Int) -> [Int] {
        var order = Array(0..<queueCount)
        order.shuffle()
        return order
    }

    // MARK: - Auto-advance (d6q.3 / d6q.4)

    /// Advance the library queue after a natural track-end event.
    ///
    /// This is the d6q.3 seam extended by d6q.4.
    ///
    /// **Repeat semantics (auto-advance only):**
    /// - `.one`: restart the same track index — do NOT call playNextInQueue().
    /// - `.all`: wrap at the end (shuffle-aware) and continue playing.
    /// - `.off`: existing behaviour — next; stop at end of queue.
    ///
    /// **Distinction from manual next/previous:**
    /// `playNextInQueue()` and `playPreviousInQueue()` are the user-gesture /
    /// remote-command path.  Repeat `.one` does NOT affect those methods —
    /// a user pressing next always moves to the adjacent track even in
    /// repeat-one mode.  Only auto-advance (this method) honours `.one`.
    ///
    /// **d6q.9 — Gapless / inter-track gap (TODO, not yet implemented):**
    /// Every track transition tears down and recreates the VLCMediaPlayer
    /// instance (`retirePlayer`), costing ~200–500 ms of silence between
    /// tracks (network-caching fill + new VLC instance init + amem bridge
    /// attach). `VLCMediaListPlayer` was ruled out — it bypasses the amem/
    /// AVAudioEngine pipeline entirely, breaking the wedge watchdog and
    /// ring-buffer path. Reusing one VLCMediaPlayer across tracks (swap
    /// `.media` without full teardown) is unvalidated and risks the
    /// 0x8BADF00D watchdog kill `retirePlayer`'s pthread_join exists to avoid.
    /// Accepted for now; revisit with a dedicated double-buffering spike if
    /// the gap becomes a real complaint.
    internal func advance() {
        guard case .library(let queue, let index) = playbackSource,
              let api = queueAPI else {
            log.log("advance: not in library mode — no-op", category: .player)
            return
        }

        switch repeatMode {
        case .one:
            // Repeat current track: restart at the same index.
            log.log("advance (repeat=.one): restarting track at index=\(index)", category: .player)
            currentQueueIndex = index
            startLibraryTrack(queue[index], inQueue: queue, at: index, via: api)

        case .all:
            if shuffleEnabled {
                // Advance the shuffle cursor; wrap at the end.
                let nextShufflePos = shufflePosition + 1
                if nextShufflePos >= shuffleOrder.count {
                    // Wrap: reshuffle the whole order (current track may reappear
                    // at any position — that is the intended behaviour on wrap).
                    log.log("advance (repeat=.all, shuffle): wrap — reshuffling \(queue.count) tracks", category: .player)
                    shuffleOrder = buildShuffleOrderFull(queueCount: queue.count)
                    shufflePosition = 0
                } else {
                    shufflePosition = nextShufflePos
                    log.log("advance (repeat=.all, shuffle): shufflePos \(shufflePosition - 1) → \(shufflePosition)", category: .player)
                }
                let nextIndex = shuffleOrder[shufflePosition]
                currentQueueIndex = nextIndex
                startLibraryTrack(queue[nextIndex], inQueue: queue, at: nextIndex, via: api)
            } else {
                // No shuffle: advance linearly, wrap at the last track.
                let nextIndex = (index + 1) % queue.count
                log.log("advance (repeat=.all): \(index) → \(nextIndex) of \(queue.count)", category: .player)
                currentQueueIndex = nextIndex
                startLibraryTrack(queue[nextIndex], inQueue: queue, at: nextIndex, via: api)
            }

        case .off:
            // Existing behaviour: next; stop at end of queue.
            playNextInQueue()
        }
    }

    /// Advances to the next track in the library queue (user-initiated).
    ///
    /// No-op when not in `.library` mode.
    ///
    /// **Edge rules (d6q.4):**
    /// - Shuffle on: advance the shuffle cursor; if at the end and repeat=.all,
    ///   wrap (reshuffle); if at the end and repeat=.off, stop.
    /// - Shuffle off, repeat=.all: wrap from last to first.
    /// - Shuffle off, repeat=.off: stop at end.
    /// - repeat=.one: `.one` does NOT trap manual next — advance to the next
    ///   track exactly as `.off` would (one step forward, stop at end unless
    ///   shuffle provides a wrap).
    public func playNextInQueue() {
        guard case .library(let queue, let index) = playbackSource,
              let api = queueAPI else {
            log.log("playNextInQueue: not in library mode — no-op", category: .player)
            return
        }

        if shuffleEnabled {
            // Advance the shuffle cursor.
            let nextShufflePos = shufflePosition + 1
            if nextShufflePos >= shuffleOrder.count {
                // End of shuffle order.
                if repeatMode == .all {
                    // Repeat-all: reshuffle and wrap.
                    shuffleOrder = buildShuffleOrderFull(queueCount: queue.count)
                    shufflePosition = 0
                } else {
                    // No repeat (or .one — same behaviour as .off for manual nav): stop.
                    log.log("playNextInQueue(shuffle): reached end of shuffle order (\(shufflePosition + 1)/\(shuffleOrder.count)) — stopping", category: .player)
                    stop()
                    return
                }
            } else {
                shufflePosition = nextShufflePos
            }
            let nextIndex = shuffleOrder[shufflePosition]
            log.log("playNextInQueue(shuffle): shufflePos \(shufflePosition), queueIndex \(index) → \(nextIndex)", category: .player)
            currentQueueIndex = nextIndex
            startLibraryTrack(queue[nextIndex], inQueue: queue, at: nextIndex, via: api)
            return
        }

        // No shuffle.
        let nextIndex: Int
        if index + 1 >= queue.count {
            if repeatMode == .all {
                // Wrap to start.
                nextIndex = 0
            } else {
                // No repeat (or .one — one is a no-trap for manual nav): stop.
                log.log("playNextInQueue: reached end of queue (\(index + 1)/\(queue.count)) — stopping", category: .player)
                stop()
                return
            }
        } else {
            nextIndex = index + 1
        }

        log.log("playNextInQueue: \(index) → \(nextIndex) of \(queue.count) (repeat=\(repeatMode))", category: .player)
        currentQueueIndex = nextIndex
        startLibraryTrack(queue[nextIndex], inQueue: queue, at: nextIndex, via: api)
    }

    /// Moves to the previous track in the library queue (user-initiated).
    ///
    /// No-op when not in `.library` mode.
    ///
    /// **Edge rules (d6q.4):**
    /// - Shuffle on: move the shuffle cursor backward; if at the start and
    ///   repeat=.all, wrap to the last shuffle position.  If repeat=.off (or
    ///   .one — no-trap for manual), restart the current track (cursor stays).
    /// - Shuffle off, repeat=.all: wrap from first track to last.
    /// - Shuffle off, repeat=.off (or .one): at index 0, restart current track
    ///   (standard iOS Music behaviour).
    public func playPreviousInQueue() {
        guard case .library(let queue, let index) = playbackSource,
              let api = queueAPI else {
            log.log("playPreviousInQueue: not in library mode — no-op", category: .player)
            return
        }

        if shuffleEnabled {
            if shufflePosition > 0 {
                shufflePosition -= 1
            } else if repeatMode == .all {
                // Wrap to end of shuffle order.
                shufflePosition = shuffleOrder.count - 1
            }
            // else: at start with no repeat — stay (restart current track).
            let prevIndex = shuffleOrder[shufflePosition]
            log.log("playPreviousInQueue(shuffle): shufflePos \(shufflePosition), queueIndex \(index) → \(prevIndex)", category: .player)
            currentQueueIndex = prevIndex
            startLibraryTrack(queue[prevIndex], inQueue: queue, at: prevIndex, via: api)
            return
        }

        // No shuffle.
        let prevIndex: Int
        if index == 0 {
            if repeatMode == .all {
                // Wrap to last track.
                prevIndex = queue.count - 1
            } else {
                // No repeat (or .one): restart current track.
                prevIndex = 0
            }
        } else {
            prevIndex = index - 1
        }

        log.log("playPreviousInQueue: \(index) → \(prevIndex) of \(queue.count) (repeat=\(repeatMode))", category: .player)
        currentQueueIndex = prevIndex
        startLibraryTrack(queue[prevIndex], inQueue: queue, at: prevIndex, via: api)
    }

    // MARK: - Shuffle + Repeat toggle API (d6q.4)

    /// Cycles repeat mode: .off → .all → .one → .off.
    ///
    /// Applies only to the `.library` queue; radio is unaffected.
    /// The change is immediate — the next auto-advance event will use the new mode.
    public func cycleRepeatMode() {
        repeatMode = repeatMode.next
        log.log("cycleRepeatMode: → \(repeatMode)", category: .player)
        persistQueuePreferences()
    }

    /// Toggle shuffle on or off.
    ///
    /// **Toggle-on:** keeps the current track playing; shuffles all remaining
    /// tracks after it in a random order.
    ///
    /// **Toggle-off:** clears the shuffle order.  Navigation resumes from the
    /// current track's natural position in the canonical queue.
    ///
    /// Applies only to the `.library` queue; radio is unaffected.
    public func toggleShuffle() {
        shuffleEnabled.toggle()
        log.log("toggleShuffle: → \(shuffleEnabled)", category: .player)

        if shuffleEnabled {
            // Build a new shuffle order, pinning the current track at position 0.
            if case .library(let queue, let index) = playbackSource {
                shuffleOrder = buildShuffleOrder(queueCount: queue.count, pinning: index)
                shufflePosition = 0
                log.log("toggleShuffle: built order for \(queue.count) tracks, current=\(index) pinned at pos 0", category: .player)
            }
        } else {
            // Restore natural order — currentQueueIndex already holds the correct
            // canonical index, so just clear the shuffle structures.
            shuffleOrder = []
            shufflePosition = 0
            log.log("toggleShuffle: cleared shuffle order, resuming from queueIndex=\(currentQueueIndex.map(String.init) ?? "nil")", category: .player)
        }

        persistQueuePreferences()
    }

    /// Persists `repeatMode` and `shuffleEnabled` to `AppSettings` so they
    /// survive app restarts.
    ///
    /// Routes through `SettingsViewModel` — the single in-memory owner of
    /// `AppSettings` — rather than doing an independent load-modify-save,
    /// which previously raced `SettingsViewModel.saveSettings()` and could
    /// silently drop whichever write lost the race (beads_mobilemusic-t96.3).
    private func persistQueuePreferences() {
        guard let settingsViewModel else {
            log.log("persistQueuePreferences: no SettingsViewModel wired, skipping", category: .player)
            return
        }
        settingsViewModel.settings.repeatMode = repeatMode
        settingsViewModel.settings.shuffleEnabled = shuffleEnabled
        Task { await settingsViewModel.saveSettings() }
    }

    /// Applies `repeatMode` and `shuffleEnabled` from loaded settings.
    /// Called by `SettingsViewModel.loadSettings()` on startup.
    public func applyQueuePreferences(repeatMode: RepeatMode, shuffleEnabled: Bool) {
        self.repeatMode = repeatMode
        self.shuffleEnabled = shuffleEnabled
        // No shuffle order to build here — no queue is active at startup.
        log.log("applyQueuePreferences: repeatMode=\(repeatMode), shuffleEnabled=\(shuffleEnabled)", category: .player)
    }

    // MARK: - Seek API (d6q.6)

    /// Seeks to the given position in the active library track.
    ///
    /// Clamped to `[0, duration]`.  No-op when in radio mode (live streams
    /// are not seekable).  After the seek, forces an immediate
    /// `MPNowPlayingInfoCenter` update so the lock-screen / CarPlay scrubber
    /// snaps to the new position without waiting for the next timer tick.
    ///
    /// Mirrors the `changePlaybackPositionCommand` remote handler so both the
    /// in-app scrubber and the lock-screen/CarPlay scrubber use the same path.
    public func seek(to seconds: Double) {
        guard case .library = playbackSource else {
            log.log("seek(to:): not in library mode — no-op", category: .player)
            return
        }
        let clampedSeconds: Double
        if let dur = trackDuration, dur > 0 {
            clampedSeconds = max(0, min(seconds, dur))
        } else {
            clampedSeconds = max(0, seconds)
        }
        let ms = Int32(exactly: (clampedSeconds * 1000).rounded()) ?? Int32(max(0, clampedSeconds * 1000))
        mediaPlayer.time = VLCTime(int: ms)
        // Force immediate now-playing flush so scrubber doesn't lag.
        lastNowPlayingElapsed = nil
        updateNowPlayingInfoForTrack()
        log.log("seek(to:): pos=\(String(format: "%.1f", clampedSeconds))s, vlcMs=\(ms)", category: .player)
    }

    // MARK: - Queue jump + reorder API (d6q.6)

    /// Jumps directly to the track at `index` in the current library queue.
    ///
    /// No-op when not in `.library` mode or when `index` is out of bounds.
    ///
    /// **Shuffle consistency:** when shuffle is on, the shuffle cursor is moved
    /// to the position of `index` in `shuffleOrder`.  If `index` is not in the
    /// current shuffle order (shouldn't happen unless the queue changed mid-shuffle),
    /// the cursor is placed at 0 and the shuffle order is rebuilt from `index`.
    public func playQueueItem(at index: Int) {
        guard case .library(let queue, _) = playbackSource,
              let api = queueAPI else {
            log.log("playQueueItem(at:): not in library mode — no-op", category: .player)
            return
        }
        guard index >= 0 && index < queue.count else {
            log.log("playQueueItem(at:): index=\(index) out of bounds for \(queue.count)-track queue — no-op", category: .player)
            return
        }

        log.log("playQueueItem(at:): jumping to index=\(index) (\"\(queue[index].title)\")", category: .player)

        currentQueueIndex = index

        // Update shuffle cursor to match the new position.
        if shuffleEnabled {
            if let pos = shuffleOrder.firstIndex(of: index) {
                shufflePosition = pos
            } else {
                // index not in current shuffle order — rebuild from this track.
                shuffleOrder = buildShuffleOrder(queueCount: queue.count, pinning: index)
                shufflePosition = 0
                log.log("playQueueItem(at:): index=\(index) not in shuffle order — rebuilt order", category: .player)
            }
        }

        startLibraryTrack(queue[index], inQueue: queue, at: index, via: api)
    }

    /// Reorders the library queue, moving the item at `sourceIndex` to
    /// `destinationIndex` (both expressed in the canonical queue order).
    ///
    /// **Playing track preservation:** the currently-playing track keeps playing
    /// and its `currentQueueIndex` is updated to reflect its new position after
    /// the move.
    ///
    /// **Shuffle consistency:** if shuffle is on, `shuffleOrder` elements (which
    /// are canonical queue indices) are remapped so the shuffle cursor still points
    /// to the now-playing track, and the relative playback order of upcoming
    /// shuffled tracks is preserved.
    ///
    /// No-op when not in `.library` mode or when either index is out of bounds.
    public func moveQueueItem(from sourceIndex: Int, to destinationIndex: Int) {
        guard case .library(let queue, let playingIndex) = playbackSource,
              queueAPI != nil else {
            log.log("moveQueueItem: not in library mode — no-op", category: .player)
            return
        }
        let count = queue.count
        guard sourceIndex >= 0 && sourceIndex < count,
              destinationIndex >= 0 && destinationIndex < count,
              sourceIndex != destinationIndex else {
            log.log("moveQueueItem: sourceIndex=\(sourceIndex) or destinationIndex=\(destinationIndex) invalid for \(count)-track queue — no-op", category: .player)
            return
        }

        log.log("moveQueueItem: \(sourceIndex) → \(destinationIndex), playingIndex=\(playingIndex), shuffle=\(shuffleEnabled)", category: .player)

        // Perform the move on the canonical queue.
        var newQueue = queue
        let item = newQueue.remove(at: sourceIndex)
        newQueue.insert(item, at: destinationIndex)

        // Compute the new canonical index of the currently-playing track.
        // A move can shift the playing index when:
        //   - sourceIndex < playingIndex and destinationIndex >= playingIndex: index shifts down by 1
        //   - sourceIndex > playingIndex and destinationIndex <= playingIndex: index shifts up by 1
        //   - sourceIndex == playingIndex: the playing track moved; index = destinationIndex
        let newPlayingIndex: Int
        if sourceIndex == playingIndex {
            newPlayingIndex = destinationIndex
        } else if sourceIndex < playingIndex && destinationIndex >= playingIndex {
            newPlayingIndex = playingIndex - 1
        } else if sourceIndex > playingIndex && destinationIndex <= playingIndex {
            newPlayingIndex = playingIndex + 1
        } else {
            newPlayingIndex = playingIndex
        }

        // Remap shuffleOrder: each element is a canonical-queue index, so apply
        // the same index-shift logic to every element in shuffleOrder.
        if shuffleEnabled && !shuffleOrder.isEmpty {
            shuffleOrder = shuffleOrder.map { idx -> Int in
                if idx == sourceIndex { return destinationIndex }
                if sourceIndex < idx && idx <= destinationIndex { return idx - 1 }
                if destinationIndex <= idx && idx < sourceIndex { return idx + 1 }
                return idx
            }
            // shufflePosition still points to the playing track's shuffle slot —
            // no change needed there since shuffleOrder[shufflePosition] was remapped.
            let remappedIdx = shufflePosition < shuffleOrder.count ? shuffleOrder[shufflePosition] : -1
            log.log("moveQueueItem: shuffleOrder remapped, shufflePosition=\(shufflePosition) now points to queueIndex=\(remappedIdx)", category: .player)
        }

        currentQueueIndex = newPlayingIndex
        // Update playbackSource with the new queue snapshot and playing index.
        playbackSource = .library(queue: newQueue, index: newPlayingIndex)

        log.log("moveQueueItem: done — newPlayingIndex=\(newPlayingIndex), queueCount=\(newQueue.count)", category: .player)
    }

    // MARK: - Scrobble helpers (65x.1)
    //
    // Implementation lives in Scrobbler.swift.  AudioPlayerService keeps a
    // forwarding static so existing call sites (including ScrobbleTests.swift)
    // compile unchanged.

    /// Forwarding alias to `Scrobbler.shouldSubmit(elapsed:duration:)`.
    /// `nonisolated` so tests can call it without a MainActor context.
    nonisolated static func scrobbleShouldSubmit(elapsed: Double, duration: Double?) -> Bool {
        Scrobbler.shouldSubmit(elapsed: elapsed, duration: duration)
    }

    private func fireNowPlayingScrobble(trackID: String, via api: NavidromeAPI) {
        scrobbler.fireNowPlaying(trackID: trackID, via: api)
    }

    internal func fireSubmissionScrobbleIfNeeded(trackID: String, via api: NavidromeAPI) {
        scrobbler.fireSubmissionIfNeeded(trackID: trackID, via: api)
    }

    /// Internal worker: tears down any active stream and starts playing a
    /// specific track within the supplied queue snapshot.
    ///
    /// All queue navigation (setQueue / playNextInQueue / playPreviousInQueue)
    /// funnels through here so there is exactly one code path that touches VLC
    /// for library playback.  The queue snapshot is the authoritative source
    /// for `playbackSource` — it is snapshotted here, not read back from the
    /// published property, so in-flight navigation can't race against a
    /// concurrent UI update.
    // MARK: - Local-first URL resolution (l31.3)

    /// Resolves the playback URL for a library track.
    ///
    /// **Local-first policy:** if `DownloadManager` reports a completed,
    /// on-disk file for this track, the local `file://` URL is returned so
    /// the track plays from disk with no network required.  Otherwise the
    /// Navidrome stream URL is used as the fallback.
    ///
    /// Radio is unaffected — this helper is only called from `startLibraryTrack`.
    ///
    /// - Parameters:
    ///   - trackID: The Navidrome track identifier.
    ///   - api: The `NavidromeAPI` instance used to build the fallback stream URL.
    /// - Returns: A `file://` URL when a completed download exists, or the
    ///   remote stream URL, or `nil` when neither can be constructed.
    func resolvePlaybackURL(trackID: String, api: NavidromeAPI) -> URL? {
        // Check local file first.
        if let localURL = DownloadManager.shared.localFileURL(forTrackID: trackID) {
            log.log("resolvePlaybackURL: local file found for trackID=\(trackID) — playing from disk", category: .player)
            return localURL
        }
        // Fall back to stream URL.
        guard let streamURL = api.streamURL(trackID: trackID) else {
            log.log("resolvePlaybackURL: stream URL construction failed for trackID=\(trackID)", category: .player)
            return nil
        }
        return streamURL
    }

    internal func startLibraryTrack(
        _ track: Track,
        inQueue queue: [Track],
        at index: Int,
        via api: NavidromeAPI
    ) {
        guard let streamURL = resolvePlaybackURL(trackID: track.id, api: api) else {
            log.log("startLibraryTrack: could not resolve playback URL for trackID=\(track.id)", category: .player)
            self.error = "Could not build stream URL for this track."
            return
        }

        let isLocal = streamURL.isFileURL
        log.log("startLibraryTrack: index=\(index)/\(queue.count) trackID=\(track.id) title=\"\(track.title)\" local=\(isLocal) url=\(streamURL.redactedForLog)", category: .player)

        // Cancel any pending radio work.
        deferredReconnectWorkItem?.cancel()
        deferredReconnectWorkItem = nil
        pendingPlayWorkItem?.cancel()
        pendingPlayWorkItem = nil
        streamProbeTask?.cancel()
        streamProbeTask = nil
        probeStartTime = nil
        interruptedChannel = nil
        interruptedSource = nil        // d6q.8
        interruptedQueueAPI = nil      // d6q.8
        interruptedElapsedSeconds = nil // d6q.8
        isRidingOutInterruption = false
        interruptionFallbackWorkItem?.cancel()
        interruptionFallbackWorkItem = nil
        if let oldURL = currentBufferFileURL {
            timeShiftBuffer.deleteBufferFile(at: oldURL)
            currentBufferFileURL = nil
        }
        isPlayingBufferedFile = false
        bufferedChannel = nil
        interruptionTime = nil
        bufferPlaybackStartedAt = nil
        timeShiftBuffer.cancelAndCleanup()
        lastLoggedVLCState = nil
        stateTimer?.invalidate()
        endBufferingBackgroundTask()

        // Stop the old player if one is running.
        let hadActiveMedia = mediaPlayer.media != nil || isActiveSession
        if hadActiveMedia {
            timed("startLibraryTrack: mediaPlayer.stop()") { mediaPlayer.stop() }
            timed("startLibraryTrack: mediaPlayer.media=nil") { mediaPlayer.media = nil }
            VLCAudioCallbackBridge.flushBuffer()
            lastTeardownTime = Date()
        }

        assertSessionOwnership(context: "startLibraryTrack")

        // Transition state: track mode sets currentChannel to nil.
        currentChannel = nil
        currentTrack = track
        // beads_mobilemusic-cpr kickback: single funnel for both play(track:)
        // and queue navigation (next/previous), so this tracks "whatever's
        // currently playing" the same way play(channel:) does for radio.
        LastPlayedItem.libraryTrack(id: track.id, albumId: track.albumId).save()
        // Artist for now-playing: prefer the track's own denormalised name (c2o,
        // works for every playback source); fall back to the queue-level display
        // artist threaded in from the album screen for older cached rows.
        let resolvedArtist = track.artist ?? queueDisplayArtistName
        currentTrackArtistName = resolvedArtist
        nowPlayingSubtitle = resolvedArtist           // in-app player subtitle (hzl)
        currentTrackArtwork = nil
        // In-app player artwork: resolve the authed cover-art URL up front so the
        // mini/full player can render it (Track.artworkURL is nil on its own).
        nowPlayingArtworkURL = track.coverArt.flatMap { api.coverArtURL(id: $0, size: 600) }
        playbackSource = .library(queue: queue, index: index)

        // 65x.1: Reset the per-track submission guard and fire the now-playing scrobble.
        scrobbler.reset()
        fireNowPlayingScrobble(trackID: track.id, via: api)
        // d6q.5: enable scrubber + ensure next/prev are on for library mode.
        updateRemoteCommandsForSource(playbackSource)

        isActiveSession = false
        isBuffering = true
        isPlaying = false
        error = nil
        streamBitrateKbps = 0
        statusText = ""
        streamTitle = nil
        streamArtist = nil
        vlcZeroByteRetryCount = 0
        channelChangeRetryCount = 0
        isReducedBufferRetry = false
        accumulatedListeningTime = 0

        trackElapsed = 0.0          // d6q.6: reset scrubber at track start
        trackDuration = nil
        listeningStartDate = Date()
        updateNowPlayingInfoForTrack()
        // Note: sxmService is radio-specific; not notified for library tracks.

        // Fetch cover art asynchronously; update now-playing when it arrives.
        if let coverArtID = track.coverArt {
            fetchTrackArtwork(coverArtID: coverArtID, size: 300, via: api, trackID: track.id)
        }

        startTrackStream(url: streamURL)
    }

    /// Low-level VLC bootstrap for on-demand track URLs.
    ///
    /// Deliberately separate from `startStream(for:channel:)` because the radio
    /// path has live-stream-specific concerns that don't apply to on-demand
    /// tracks: `--http-reconnect`, `scheduleDeferredReconnect`, the interruption
    /// fallback safety-net, and the zero-byte probe-and-retry loop.  Mixing those
    /// concerns into a shared primitive creates risk without benefit for a finite
    /// on-demand stream.
    ///
    /// The shared elements (`retirePlayer`, amem bridge, session ownership) are
    /// preserved exactly.  Radio behaviour is provably unchanged — this method is
    /// never called from any radio code path.
    private func startTrackStream(url: URL) {
        streamStartTime = Date()
        wasAwaitingInitialBuffer = false
        hasReceivedData = false
        lastDataFlowTime = nil
        lastActiveDecodedAudio = 0
        lastLoggedLostAudioBuffers = 0
        lastLoggedDiscontinuity = 0

        let cacheMs = Int(bufferDuration * 1000)
        log.log("startTrackStream: network-caching=\(cacheMs)ms url=\(url.redactedForLog)", category: .player)
        retirePlayer(options: [
            "--network-caching=\(cacheMs)",
        ])

        let media = VLCMedia(url: url)
        media.addOptions(["http-user-agent": "AdagioStream/1.0"])
        media.delegate = self
        mediaPlayer.media = media
        mediaPlayer.audio?.volume = 100

        AudioOutput.shared.start()
        VLCAudioCallbackBridge.resetRenderCounters()

        let preAttachPlay = VLCAudioCallbackBridge.playCallbackCount
        let attached = VLCAudioCallbackBridge.attachAudioCallbacks(
            to: mediaPlayer,
            sampleRate: AudioOutput.sampleRate,
            channels: AudioOutput.channelCount
        )
        log.log("amem bridge (track): attached=\(attached), priorPlayCount=\(preAttachPlay)", category: .audioSession)

        mediaPlayer.play()
        isActiveSession = true
        log.log("startTrackStream started: playerState=\(vlcStateName(mediaPlayer.state)), willPlay=\(mediaPlayer.willPlay)", category: .player)

        currentPollInterval = fastPollInterval
        startStateTimer(interval: fastPollInterval)
    }

    /// Fetches track artwork through ImageCacheService using the stable cover-art
    /// key (host + coverArtID + size), so per-request auth salts do not bust the
    /// cache.  Replaces the previous URL-keyed `ephemeralImage(for:)` call.
    private func fetchTrackArtwork(coverArtID: String, size: Int, via api: NavidromeAPI, trackID: String) {
        Task {
            guard let image = await api.fetchCoverArtImage(id: coverArtID, size: size) else { return }
            guard self.currentTrack?.id == trackID else { return }
            self.currentTrackArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.updateNowPlayingInfoForTrack()
        }
    }
}
