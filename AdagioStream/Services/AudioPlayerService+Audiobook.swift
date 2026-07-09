import AVFoundation
import Foundation
import MediaPlayer
@preconcurrency import VLCKitSPM

// Audiobookshelf E2 (yu8.2 playback + chaining, yu8.3 sync/resume, yu8.4 chapters).
//
// Audiobook playback is a self-contained path that reuses the same VLC
// primitives as radio/library (retirePlayer, amem bridge, state timer, .ended
// chaining) but keeps its own book-global timeline. See AudiobookTimeline for
// the pure global↔file math (unit-tested); this file wires it to VLC + the ABS
// server (open session, sync progress, close).

/// Mutable session state for one playing audiobook.
final class AudiobookSession {
    let book: Audiobook
    let sessionID: String
    let timeline: AudiobookTimeline
    let api: AudiobookshelfAPI

    /// Offline session (E3 / mkj.2): files play from local `file://` URLs and
    /// progress is queued via `ABSProgressSyncQueue` instead of `/session/sync`.
    let isOffline: Bool

    /// The file currently loaded into VLC.
    var currentFile: AudiobookTimeline.File

    /// Book-global offset at which the currently-loaded file started playing.
    /// `globalTime == currentFile.startOffset + (VLC per-file seconds)`.
    var fileStartOffset: Double { currentFile.startOffset }

    /// Last book-global time reported to the server, for `timeListened` deltas.
    var lastSyncedGlobalTime: Double
    /// Wall-clock of the last successful sync, to throttle to ~20s.
    var lastSyncDate: Date

    init(book: Audiobook, sessionID: String, timeline: AudiobookTimeline, api: AudiobookshelfAPI, startFile: AudiobookTimeline.File, startGlobalTime: Double, isOffline: Bool = false) {
        self.book = book
        self.sessionID = sessionID
        self.timeline = timeline
        self.api = api
        self.isOffline = isOffline
        self.currentFile = startFile
        self.lastSyncedGlobalTime = startGlobalTime
        self.lastSyncDate = Date()
    }
}

extension AudioPlayerService {

    /// A stable per-install device id for the ABS `deviceInfo`. Reused across
    /// sessions so the server can dedupe our devices.
    static var absDeviceID: String {
        let key = "abs.deviceId"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    // MARK: - Pure helpers (unit-tested)

    /// Resume-position precedence (yu8.3): an explicit override wins, then the
    /// server's `/play` currentTime (seeded from user progress), then the last
    /// cached book record. `nil` server value falls through.
    static func resumePosition(override: Double?, sessionCurrentTime: Double?, bookCurrentTime: Double) -> Double {
        override ?? sessionCurrentTime ?? bookCurrentTime
    }

    /// `timeListened` for a sync: seconds advanced since the last sync, clamped
    /// to ≥ 0 so a backward seek never reports negative listen time.
    static func timeListened(sinceLastSynced last: Double, currentGlobal: Double) -> Double {
        max(0, currentGlobal - last)
    }

    /// The larger of two optional positions, ignoring `nil`. Used to prefer an
    /// unflushed offline position over the server's `/play` currentTime so a
    /// reconnect never resumes behind where the user listened offline (ymf.6).
    static func maxIgnoringNil(_ a: Double?, _ b: Double?) -> Double? {
        switch (a, b) {
        case let (x?, y?): return max(x, y)
        case let (x?, nil): return x
        case let (nil, y?): return y
        case (nil, nil): return nil
        }
    }

    // MARK: - Start / resume

    /// Opens a playback session for `book` and starts playing at the server's
    /// resume position (or `startGlobalTime` if given). Reuses the VLC pipeline.
    ///
    /// Offline routing (E3 / mkj.2): if the book is fully downloaded AND either
    /// offline mode is on or the server session can't be opened, play from local
    /// files instead. Respects the existing `offlineMode` app setting.
    public func playAudiobook(_ book: Audiobook, via api: AudiobookshelfAPI, startGlobalTime: Double? = nil) {
        log.log("playAudiobook: \"\(book.title)\" id=\(book.id)", category: .player)

        let offlineMode = settingsViewModel?.settings.offlineMode ?? false
        let downloaded = DownloadManager.shared.downloadedBook(itemID: book.id)

        // Offline mode + a local copy → play offline directly, no network.
        if offlineMode, let downloaded {
            playDownloadedAudiobook(book, download: downloaded, via: api, startGlobalTime: startGlobalTime)
            return
        }
        // Offline mode but no local copy → surface a clear error.
        if offlineMode {
            self.error = "This audiobook isn't downloaded for offline listening."
            return
        }

        Task { @MainActor in
            do {
                // ymf.6: flush any offline progress for THIS book before opening a
                // live session, so the server holds the offline-max position first.
                // If the flush doesn't land (network), seed the resume from the
                // still-queued position so the live session can't rewind to an
                // older server currentTime under last-writer-wins.
                await ABSProgressSyncQueue.shared.flush(via: api)
                let offlinePending = await ABSProgressSyncQueue.shared.pendingPosition(forBook: book.id)

                let session = try await api.openPlaybackSession(itemID: book.id, deviceID: AudioPlayerService.absDeviceID)
                let timeline = AudiobookTimeline(session: session, bookId: book.id)
                guard !timeline.files.isEmpty else {
                    self.error = "This audiobook has no playable files."
                    return
                }
                // Resume point: explicit override → offline-max (unflushed) →
                // server currentTime → book record. Never rewind past a position
                // the user reached offline (ymf.6).
                let resume = AudioPlayerService.resumePosition(
                    override: startGlobalTime,
                    sessionCurrentTime: AudioPlayerService.maxIgnoringNil(offlinePending, session.currentTime),
                    bookCurrentTime: book.currentTime
                )
                guard let located = timeline.locate(global: resume) else { return }

                let abs = AudiobookSession(
                    book: book,
                    sessionID: session.id,
                    timeline: timeline,
                    api: api,
                    startFile: located.file,
                    startGlobalTime: resume
                )
                self.audiobookSession = abs
                self.currentAudiobook = book
                self.audiobookDuration = timeline.totalDuration
                self.audiobookGlobalTime = resume
                self.currentChapter = timeline.chapter(at: resume)
                // Resolve cover art for the in-app player + lock screen.
                self.currentTrackArtwork = nil
                self.nowPlayingArtworkURL = await api.coverURL(itemID: book.id)
                self.loadAudiobookArtwork(itemID: book.id, api: api)
                self.loadAudiobookFile(located.file, fileOffset: located.fileOffset)
            } catch {
                // Server unreachable but we have a local copy → play offline.
                if let downloaded {
                    self.log.log("playAudiobook: server failed, falling back to offline", category: .player)
                    self.playDownloadedAudiobook(book, download: downloaded, via: api, startGlobalTime: startGlobalTime)
                    return
                }
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.log.log("playAudiobook failed: \(error)", category: .player)
            }
        }
    }

    /// Plays a fully-downloaded book from local files. Rebuilds the SAME
    /// `AudiobookTimeline` as streaming from the persisted manifest (each file's
    /// global `startOffset`), so chaining, seeking, and chapter math are
    /// identical — only the URLs are `file://` and progress is queued offline.
    public func playDownloadedAudiobook(_ book: Audiobook, download: AudiobookDownloadRecord, via api: AudiobookshelfAPI, startGlobalTime: Double? = nil) {
        let timeline = download.timeline()
        guard !timeline.files.isEmpty else {
            self.error = "This download is incomplete."
            return
        }
        let resume = AudioPlayerService.resumePosition(
            override: startGlobalTime,
            sessionCurrentTime: nil,
            bookCurrentTime: book.currentTime
        )
        guard let located = timeline.locate(global: resume) else { return }

        let abs = AudiobookSession(
            book: book,
            sessionID: "",            // no server session offline
            timeline: timeline,
            api: api,
            startFile: located.file,
            startGlobalTime: resume,
            isOffline: true
        )
        self.audiobookSession = abs
        self.currentAudiobook = book
        self.audiobookDuration = timeline.totalDuration
        self.audiobookGlobalTime = resume
        self.currentChapter = timeline.chapter(at: resume)
        self.currentTrackArtwork = nil
        self.nowPlayingArtworkURL = nil
        loadAudiobookFile(located.file, fileOffset: located.fileOffset)
    }

    /// Loads one file into VLC seeked to `fileOffset` seconds. Mirrors the
    /// library-track VLC bootstrap; audiobooks never use the radio-only reconnect
    /// / probe / interruption-fallback machinery.
    internal func loadAudiobookFile(_ file: AudiobookTimeline.File, fileOffset: Double) {
        guard let session = audiobookSession else { return }
        // Offline: contentPath is an absolute local file path → play it directly.
        if session.isOffline {
            session.currentFile = file
            startAudiobookStream(url: URL(fileURLWithPath: file.contentPath), seekTo: fileOffset)
            return
        }
        Task { @MainActor in
            guard let url = await session.api.streamURL(contentPath: file.contentPath) else {
                self.error = "Could not build audiobook stream URL."
                return
            }
            session.currentFile = file
            self.startAudiobookStream(url: url, seekTo: fileOffset)
        }
    }

    private func startAudiobookStream(url: URL, seekTo fileOffset: Double) {
        // Radio/library-shared VLC teardown + fresh player.
        currentChannel = nil
        currentTrack = nil
        streamStartTime = Date()
        lastLoggedVLCState = nil
        stateTimer?.invalidate()

        let hadActiveMedia = mediaPlayer.media != nil || isActiveSession
        if hadActiveMedia {
            timed("startAudiobookStream: mediaPlayer.stop()") { mediaPlayer.stop() }
            timed("startAudiobookStream: mediaPlayer.media=nil") { mediaPlayer.media = nil }
            VLCAudioCallbackBridge.flushBuffer()
            lastTeardownTime = Date()
        }

        assertSessionOwnership(context: "startAudiobookStream")

        let cacheMs = Int(bufferDuration * 1000)
        retirePlayer(options: ["--network-caching=\(cacheMs)"])

        let media = VLCMedia(url: url)
        media.addOptions(["http-user-agent": "AdagioStream/1.0"])
        media.delegate = self
        mediaPlayer.media = media
        mediaPlayer.audio?.volume = 100

        AudioOutput.shared.start()
        VLCAudioCallbackBridge.resetRenderCounters()
        _ = VLCAudioCallbackBridge.attachAudioCallbacks(
            to: mediaPlayer,
            sampleRate: AudioOutput.sampleRate,
            channels: AudioOutput.channelCount
        )

        isActiveSession = false
        isBuffering = true
        isPlaying = false
        error = nil
        listeningStartDate = Date()

        mediaPlayer.play()
        // Seek within the file once VLC actually reports it can seek (f0d). We
        // arm a pending seek here and apply it from `syncState` when VLC becomes
        // seekable, instead of a blind wall-clock delay. `applyPendingAudiobookSeek`
        // carries a bounded fallback so a stuck stream can't hang the seek.
        if fileOffset > 0.5 {
            pendingAudiobookSeekMs = Int32(exactly: (fileOffset * 1000).rounded()) ?? 0
            pendingAudiobookSeekDeadline = Date().addingTimeInterval(AudioPlayerService.audiobookSeekFallbackTimeout)
        } else {
            pendingAudiobookSeekMs = nil
            pendingAudiobookSeekDeadline = nil
        }
        isActiveSession = true
        updateNowPlayingInfoForAudiobook()

        currentPollInterval = fastPollInterval
        startStateTimer(interval: fastPollInterval)
        log.log("startAudiobookStream: file=\(mediaPlayerFileLabel()) seek=\(String(format: "%.1f", fileOffset))s", category: .player)
    }

    private func mediaPlayerFileLabel() -> String {
        audiobookSession.map { "\($0.currentFile.index)/\($0.timeline.files.count)" } ?? "?"
    }

    // MARK: - Global position + chaining (called from syncState on the .ended path)

    /// Current book-global time from VLC's per-file position.
    internal var audiobookCurrentGlobalTime: Double {
        guard let session = audiobookSession else { return 0 }
        let vlcMs = mediaPlayer.time.intValue
        let fileSeconds = vlcMs > 0 ? Double(vlcMs) / 1000.0 : 0
        return session.timeline.globalTime(file: session.currentFile, fileOffset: fileSeconds)
    }

    /// Called each timer tick while an audiobook plays: publishes global time,
    /// current chapter, and drives the ~20s progress sync.
    internal func tickAudiobook() {
        guard let session = audiobookSession else { return }
        let global = audiobookCurrentGlobalTime
        if abs(global - audiobookGlobalTime) > 0.2 { audiobookGlobalTime = global }
        let chapter = session.timeline.chapter(at: global)
        if chapter != currentChapter {
            currentChapter = chapter
            updateNowPlayingInfoForAudiobook()
        }
        // Throttled progress sync (yu8.3).
        if Date().timeIntervalSince(session.lastSyncDate) >= 20 {
            syncAudiobookProgress()
        }
    }

    /// Called from the VLC `.ended` branch when an audiobook file finishes:
    /// chain to the next file, or close the session at end-of-book.
    internal func audiobookFileEnded() {
        guard let session = audiobookSession else { return }
        // Report the file boundary as progress before chaining.
        syncAudiobookProgress(force: true)
        if let next = session.timeline.fileAfter(session.currentFile) {
            log.log("audiobook: file \(session.currentFile.index) ended — chaining to \(next.index)", category: .player)
            loadAudiobookFile(next, fileOffset: 0)
        } else {
            log.log("audiobook: reached end of book \"\(session.book.title)\"", category: .player)
            stopAudiobook()
        }
    }

    // MARK: - Initial per-file seek (f0d — state-observed)

    /// Upper bound on how long we wait for VLC to report seekable before applying
    /// the initial seek anyway. VLCKit has no ready-to-seek callback for network
    /// media; observing `isSeekable` is the primary signal, this is the ceiling.
    // ponytail: fixed fallback ceiling; raise only if slow streams miss the seek.
    static let audiobookSeekFallbackTimeout: TimeInterval = 5.0

    /// Whether the armed initial seek should fire now: apply as soon as VLC says
    /// it can seek (and has parsed a length), or once the fallback deadline passes.
    /// Pure so the trigger logic is unit-testable without VLC.
    nonisolated static func shouldApplyAudiobookSeek(isSeekable: Bool, hasLength: Bool, now: Date, deadline: Date) -> Bool {
        (isSeekable && hasLength) || now >= deadline
    }

    /// Called from `syncState` while an audiobook is active: applies the armed
    /// initial per-file seek once VLC is ready (or the fallback fires), then
    /// disarms it. No-op when nothing is pending.
    internal func applyPendingAudiobookSeek() {
        guard let ms = pendingAudiobookSeekMs, let deadline = pendingAudiobookSeekDeadline else { return }
        let hasLength = mediaPlayer.media?.length.intValue ?? 0 > 0
        guard AudioPlayerService.shouldApplyAudiobookSeek(
            isSeekable: mediaPlayer.isSeekable,
            hasLength: hasLength,
            now: Date(),
            deadline: deadline
        ) else { return }
        mediaPlayer.time = VLCTime(int: ms)
        pendingAudiobookSeekMs = nil
        pendingAudiobookSeekDeadline = nil
        log.log("audiobook: applied initial seek to \(ms)ms (seekable=\(mediaPlayer.isSeekable))", category: .player)
    }

    // MARK: - Seek (book-global) + chapter skip (yu8.4)

    /// Seeks to a book-global time. If the target lands in a different file,
    /// loads that file seeked to the right per-file offset; otherwise seeks VLC
    /// within the current file. Reuses `AudiobookTimeline.locate`.
    public func seekAudiobook(toGlobal t: Double) {
        guard let session = audiobookSession, let located = session.timeline.locate(global: t) else { return }
        audiobookGlobalTime = located.file.startOffset + located.fileOffset
        currentChapter = session.timeline.chapter(at: audiobookGlobalTime)
        if located.file.index == session.currentFile.index {
            let ms = Int32(exactly: (located.fileOffset * 1000).rounded()) ?? 0
            mediaPlayer.time = VLCTime(int: ms)
            updateNowPlayingInfoForAudiobook()
        } else {
            loadAudiobookFile(located.file, fileOffset: located.fileOffset)
        }
        syncAudiobookProgress(force: true)
    }

    /// Skips to the next chapter (global-timeline seek). No-op past the last.
    public func skipToNextChapter() {
        guard let session = audiobookSession,
              let start = session.timeline.nextChapterStart(after: audiobookCurrentGlobalTime) else { return }
        seekAudiobook(toGlobal: start)
    }

    /// Skips to the previous chapter (or restarts current — iOS Music behaviour).
    public func skipToPreviousChapter() {
        guard let session = audiobookSession,
              let start = session.timeline.previousChapterStart(from: audiobookCurrentGlobalTime) else { return }
        seekAudiobook(toGlobal: start)
    }

    // MARK: - Progress sync (yu8.3)

    /// Reports book-global progress to the server. Throttled by `tickAudiobook`;
    /// `force` bypasses the throttle (pause, seek, background, file boundary,
    /// stop). On a 404 the session expired — reopen via `/play` at the current
    /// position so playback continues syncing.
    internal func syncAudiobookProgress(force: Bool = false) {
        guard let session = audiobookSession else { return }
        let global = audiobookCurrentGlobalTime
        let listened = AudioPlayerService.timeListened(sinceLastSynced: session.lastSyncedGlobalTime, currentGlobal: global)
        let duration = session.timeline.totalDuration
        session.lastSyncedGlobalTime = global
        session.lastSyncDate = Date()
        let sessionID = session.sessionID
        let api = session.api
        let book = session.book

        // Offline session → queue the progress for a batched flush on reconnect.
        if session.isOffline {
            let update = ABSProgressUpdate(
                libraryItemId: book.id,
                currentTime: global,
                duration: duration,
                isFinished: duration > 0 && global >= duration - 1.0
            )
            Task { await ABSProgressSyncQueue.shared.enqueue(update) }
            _ = force
            return
        }

        Task { @MainActor in
            do {
                let status = try await api.syncSession(
                    sessionID: sessionID,
                    currentTime: global,
                    timeListened: listened,
                    duration: duration
                )
                if status == 404 {
                    self.log.log("audiobook sync 404 — session expired, reopening", category: .player)
                    // Only reopen if we're still playing this same book.
                    if self.audiobookSession?.sessionID == sessionID {
                        self.reopenAudiobookSession(book: book, api: api, atGlobal: global)
                    }
                }
            } catch {
                self.log.log("audiobook sync error: \(error)", category: .player)
            }
        }
        _ = force // force only affects whether the caller bypassed the tick throttle
    }

    /// Reopens a fresh `/play` session (after a 404) keeping the current
    /// position, without tearing down VLC if the current file still matches.
    private func reopenAudiobookSession(book: Audiobook, api: AudiobookshelfAPI, atGlobal global: Double) {
        Task { @MainActor in
            guard let fresh = try? await api.openPlaybackSession(itemID: book.id, deviceID: AudioPlayerService.absDeviceID) else { return }
            guard self.audiobookSession != nil else { return }
            let timeline = AudiobookTimeline(session: fresh, bookId: book.id)
            guard let located = timeline.locate(global: global) else { return }
            let abs = AudiobookSession(
                book: book, sessionID: fresh.id, timeline: timeline, api: api,
                startFile: located.file, startGlobalTime: global
            )
            self.audiobookSession = abs
            // VLC keeps playing the same file if it matches; only the session id
            // changes for future syncs.
        }
    }

    // MARK: - Pause / stop

    /// Pauses an audiobook: keeps the session, flushes a progress sync.
    internal func pauseAudiobook() {
        syncAudiobookProgress(force: true)
    }

    /// Stops an audiobook, closing the server session (releases transcode
    /// resources) and clearing state.
    public func stopAudiobook() {
        guard let session = audiobookSession else { return }
        syncAudiobookProgress(force: true)
        if !session.isOffline {
            let sessionID = session.sessionID
            let api = session.api
            Task { await api.closeSession(sessionID: sessionID) }
        }
        audiobookSession = nil
        currentAudiobook = nil
        audiobookDuration = nil
        audiobookGlobalTime = 0
        currentChapter = nil
    }

    // MARK: - Now Playing (yu8.4 — chapter title + book metadata)

    /// Publishes lock-screen / Control Center info for the current audiobook:
    /// chapter title as the track title, book title as album, author as artist,
    /// with book-global elapsed/duration so the scrubber spans the whole book.
    internal func updateNowPlayingInfoForAudiobook() {
        guard let session = audiobookSession else { return }
        let global = audiobookGlobalTime
        let chapterTitle = currentChapter?.title
        let title = chapterTitle ?? session.book.title
        let rate: Double = isPlaying ? 1.0 : 0.0
        let state: MPNowPlayingPlaybackState = (isPlaying || isBuffering) ? .playing : .paused

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: session.book.author ?? "",
            MPMediaItemPropertyAlbumTitle: session.book.title,
            MPNowPlayingInfoPropertyIsLiveStream: false,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: global,
            MPMediaItemPropertyPlaybackDuration: NSNumber(value: session.timeline.totalDuration),
        ]
        if let artwork = currentTrackArtwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = state
    }

    /// Loads the book cover into `currentTrackArtwork` for the lock screen /
    /// Control Center. UIKit-only (no artwork on tvOS lock screen here).
    private func loadAudiobookArtwork(itemID: String, api: AudiobookshelfAPI) {
        #if canImport(UIKit)
        Task { @MainActor in
            guard let url = await api.coverURL(itemID: itemID),
                  let image = await ImageCacheService.shared.image(for: url) else { return }
            guard self.audiobookSession?.book.id == itemID else { return }
            self.currentTrackArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.updateNowPlayingInfoForAudiobook()
        }
        #endif
    }
}
