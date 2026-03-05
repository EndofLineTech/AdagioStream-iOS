import AVFoundation
import CallKit
import Combine
import MediaPlayer
import SwiftUI
import VLCKitSPM

@MainActor
final class AudioPlayerService: NSObject, ObservableObject, VLCMediaPlayerDelegate, VLCMediaDelegate {
    static let shared = AudioPlayerService()
    private let log = DebugLogger.shared

    @Published var currentChannel: Channel?
    @Published var isPlaying = false
    @Published var isBuffering = false
    @Published var error: String?
    @Published var streamBitrateKbps: Double = 0
    @Published var statusText: String = ""
    @Published var listeningDuration: TimeInterval = 0

    let timeShiftBuffer = TimeShiftBufferService.shared
    let sxmService = SXMMetadataService.shared

    private var mediaPlayer = VLCMediaPlayer()
    private let callObserver = CXCallObserver()
    private let callDelegate = CallObserverDelegate()
    private var sxmCancellable: AnyCancellable?
    private var listeningStartDate: Date?
    private var accumulatedListeningTime: TimeInterval = 0
    private var stateTimer: Timer?
    private var currentArtwork: MPMediaItemArtwork?
    private var sxmArtwork: MPMediaItemArtwork?
    private var lastPlayedChannel: Channel?
    private var interruptedChannel: Channel?
    private var isActiveSession = false
    private var lastToggleTime: Date = .distantPast
    private var lastLoggedVLCState: VLCMediaPlayerState?
    private var channelChangeRetryCount = 0
    private let maxChannelChangeRetries = 3
    private var pendingPlayWorkItem: DispatchWorkItem?
    private var lastTeardownTime: Date = .distantPast
    private var isPlayingBufferedFile = false
    private var bufferedChannel: Channel?
    private var currentBufferFileURL: URL?

    var channels: [Channel] = []
    var bufferDuration: TimeInterval = Constants.defaultBufferDuration

    private override init() {
        super.init()
        log.log("AudioPlayerService init", category: .player)
        mediaPlayer.delegate = self
        callObserver.setDelegate(callDelegate, queue: nil)
        configureAudioSession()
        configureRemoteCommands()
        // Live Activity disabled — system Now Playing widget is sufficient

        sxmCancellable = sxmService.$currentTrack
            .receive(on: DispatchQueue.main)
            .sink { [weak self] track in
                guard let self else { return }
                self.sxmArtwork = nil
                if let track, let artworkURL = track.artworkURL {
                    self.fetchSXMArtwork(url: artworkURL, trackID: track.id)
                }
                self.updateNowPlayingInfo()
            }
    }

    // MARK: - Audio Session

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
            try session.setActive(true)
            log.log("Audio session configured: category=playback, policy=longFormAudio", category: .audioSession)
        } catch {
            log.log("Audio session config FAILED: \(error.localizedDescription)", category: .audioSession)
            self.error = "Failed to configure audio session: \(error.localizedDescription)"
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioInterruption),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance()
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSilenceSecondaryAudio),
            name: AVAudioSession.silenceSecondaryAudioHintNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    @objc nonisolated private func handleSilenceSecondaryAudio(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? UInt,
              let type = AVAudioSession.SilenceSecondaryAudioHintType(rawValue: typeValue) else { return }
        let hintName: String
        switch type {
        case .begin: hintName = "BEGIN (system audio started, e.g. Siri/Voice Control)"
        case .end: hintName = "END (system audio stopped)"
        @unknown default: hintName = "rawValue(\(typeValue))"
        }
        DebugLogger.shared.log("Secondary audio hint: \(hintName), otherAudioPlaying=\(AVAudioSession.sharedInstance().isOtherAudioPlaying)", category: .interruption)

        // Safety fallback: if .ended interruption never fires (common with
        // CarPlay Siri), the .end hint tells us the other audio stopped.
        // Treat it as the interruption ending and resume.
        if type == .end {
            Task { @MainActor in
                guard let channel = self.interruptedChannel else { return }
                self.log.log("Secondary audio hint .end: resuming interrupted channel \"\(channel.name)\"", category: .interruption)
                self.interruptedChannel = nil
                let bufferFileURL = self.timeShiftBuffer.stopCapture()
                self.log.log("Time-shift buffer: \(bufferFileURL != nil ? "available" : "none")", category: .interruption)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.reactivateAndPlay(channel: channel, bufferFileURL: bufferFileURL)
                }
            }
        }
    }

    @objc nonisolated private func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.map { "\($0.portName) (\($0.portType.rawValue))" }.joined(separator: ", ")
        let inputs = session.currentRoute.inputs.map { "\($0.portName) (\($0.portType.rawValue))" }.joined(separator: ", ")
        let reasonName: String
        switch reason {
        case .newDeviceAvailable: reasonName = "newDeviceAvailable"
        case .oldDeviceUnavailable: reasonName = "oldDeviceUnavailable"
        case .categoryChange: reasonName = "categoryChange"
        case .override: reasonName = "override"
        case .wakeFromSleep: reasonName = "wakeFromSleep"
        case .noSuitableRouteForCategory: reasonName = "noSuitableRouteForCategory"
        case .routeConfigurationChange: reasonName = "routeConfigurationChange"
        case .unknown: reasonName = "unknown"
        @unknown default: reasonName = "rawValue(\(reasonValue))"
        }

        let isCarPlayOutput = session.currentRoute.outputs.contains { $0.portType == .carAudio }
        let prevRouteDesc: String
        if let prev = userInfo[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription {
            prevRouteDesc = prev.outputs.map { "\($0.portName) (\($0.portType.rawValue))" }.joined(separator: ", ")
        } else {
            prevRouteDesc = "unknown"
        }

        DebugLogger.shared.log("Route change: reason=\(reasonName), carplay=\(isCarPlayOutput), outputs=[\(outputs)], inputs=[\(inputs)], prev=[\(prevRouteDesc)], otherAudio=\(session.isOtherAudioPlaying)", category: .audioSession)
    }

    @objc nonisolated private func handleAudioInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        Task { @MainActor in
            switch type {
            case .began:
                self.log.log("Interruption BEGAN: isActive=\(self.isActiveSession), channel=\"\(self.currentChannel?.name ?? "nil")\", vlcState=\(self.mediaPlayer.state.rawValue)", category: .interruption)
                self.logAudioSessionSnapshot("interruption.began")

                // Remember what was playing, then stop the stream cleanly.
                // VLC's state becomes unpredictable after audio session
                // interruptions — a fresh start on .ended is more reliable.
                if self.isActiveSession, let channel = self.currentChannel {
                    self.interruptedChannel = channel
                    let currentBitrate = self.streamBitrateKbps
                    self.log.log("Saving interrupted channel \"\(channel.name)\", stopping stream", category: .interruption)
                    self.stop()

                    // Start capturing stream data so we can resume from
                    // the interruption point instead of rejoining live
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        guard self.interruptedChannel?.id == channel.id else { return }
                        self.timeShiftBuffer.startCapture(for: channel, estimatedBitrateKbps: currentBitrate)
                    }
                }

            case .ended:
                let options = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let shouldResume = AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
                self.log.log("Interruption ENDED: interruptedChannel=\"\(self.interruptedChannel?.name ?? "nil")\", shouldResume=\(shouldResume)", category: .interruption)
                self.logAudioSessionSnapshot("interruption.ended")

                guard let channel = self.interruptedChannel else {
                    self.log.log("Interruption ended but no interrupted channel, skipping resume", category: .interruption)
                    return
                }
                self.interruptedChannel = nil

                // Stop time-shift capture and get buffer file if available
                let bufferFileURL = self.timeShiftBuffer.stopCapture()
                self.log.log("Time-shift buffer: \(bufferFileURL != nil ? "available" : "none")", category: .interruption)

                // Delay to let the audio route settle (CarPlay route transitions
                // need time to switch back from phone/Siri to media output).
                self.log.log("Scheduling 500ms delayed restart for \"\(channel.name)\"", category: .interruption)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.reactivateAndPlay(channel: channel, bufferFileURL: bufferFileURL)
                }

            @unknown default:
                self.log.log("Interruption UNKNOWN type: \(typeValue)", category: .interruption)
                break
            }
        }
    }

    private func logAudioSessionSnapshot(_ context: String) {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.map { "\($0.portName) (\($0.portType.rawValue))" }.joined(separator: ", ")
        let inputs = session.currentRoute.inputs.map { "\($0.portName) (\($0.portType.rawValue))" }.joined(separator: ", ")
        let isCarPlay = session.currentRoute.outputs.contains { $0.portType == .carAudio }
        let activeCalls = callObserver.calls.map { call -> String in
            let state: String
            if call.hasConnected { state = "connected" }
            else if call.hasEnded { state = "ended" }
            else if call.isOutgoing { state = "outgoing-ringing" }
            else { state = "incoming-ringing" }
            return "\(state)(onHold=\(call.isOnHold))"
        }
        let callInfo = activeCalls.isEmpty ? "none" : activeCalls.joined(separator: ", ")
        log.log("Session[\(context)]: cat=\(session.category.rawValue), mode=\(session.mode.rawValue), otherAudio=\(session.isOtherAudioPlaying), silenceHint=\(session.secondaryAudioShouldBeSilencedHint), carplay=\(isCarPlay), outputs=[\(outputs)], inputs=[\(inputs)], calls=[\(callInfo)]", category: .audioSession)
    }

    private func reactivateAndPlay(channel: Channel, bufferFileURL: URL? = nil) {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.map { "\($0.portName) (\($0.portType.rawValue))" }.joined(separator: ", ")
        log.log("reactivateAndPlay: channel=\"\(channel.name)\", buffer=\(bufferFileURL != nil), outputs=[\(outputs)]", category: .audioSession)

        // Deactivate first to fully release the old audio route, then
        // reactivate — this resets stale hardware state that can prevent
        // VLC from reconnecting after CarPlay interruptions
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            log.log("Session deactivated OK", category: .audioSession)
        } catch {
            log.log("Session deactivate FAILED: \(error.localizedDescription)", category: .audioSession)
        }
        do {
            try session.setActive(true)
            log.log("Session reactivated OK", category: .audioSession)
        } catch {
            log.log("Session reactivate FAILED: \(error.localizedDescription)", category: .audioSession)
        }

        if let bufferFileURL {
            playBufferedFile(bufferFileURL, for: channel)
        } else {
            play(channel: channel)
        }
    }

    // MARK: - Playback

    func play(channel: Channel) {
        log.log("play() channel=\"\(channel.name)\" group=\"\(channel.group)\" url=\(channel.streamURL.absoluteString)", category: .player)

        // Cancel any pending stream start from a previous rapid channel tap
        pendingPlayWorkItem?.cancel()
        pendingPlayWorkItem = nil
        interruptedChannel = nil
        if let oldURL = currentBufferFileURL {
            timeShiftBuffer.deleteBufferFile(at: oldURL)
            currentBufferFileURL = nil
        }
        isPlayingBufferedFile = false
        bufferedChannel = nil
        timeShiftBuffer.cancelAndCleanup()
        lastLoggedVLCState = nil
        stateTimer?.invalidate()

        // Destroy the old VLCMediaPlayer entirely and create a fresh one.
        // VLC's stop() is async — the HTTP socket can linger for seconds.
        // Xtream Codes servers enforce a per-account connection limit and
        // 403 new requests while the old one is still open.  Deallocating
        // the player guarantees all internal threads and sockets are torn
        // down before we open a new connection.
        let hadActiveMedia = mediaPlayer.media != nil || isActiveSession
        if hadActiveMedia {
            log.log("Destroying old VLCMediaPlayer to release connection", category: .player)
            mediaPlayer.stop()
            mediaPlayer.media = nil
            mediaPlayer.delegate = nil
            mediaPlayer = VLCMediaPlayer()
            mediaPlayer.delegate = self
            lastTeardownTime = Date()
        }

        let channelChanged = currentChannel?.id != channel.id
        currentChannel = channel
        isActiveSession = false
        isBuffering = true
        isPlaying = false
        error = nil
        streamBitrateKbps = 0
        statusText = ""
        if channelChanged {
            channelChangeRetryCount = 0
            accumulatedListeningTime = 0
            listeningDuration = 0
            currentArtwork = nil
            fetchArtwork(for: channel)
        }
        listeningStartDate = Date()
        updateNowPlayingInfo()
        sxmService.channelChanged(to: channel)

        // Debounce: each tap resets a 1.5s timer.  The stream only starts
        // once the user has stopped switching for 1.5s.  This prevents
        // opening (and immediately tearing down) connections while the
        // user scrolls through channels, which upsets Xtream Codes servers.
        let needsDelay = lastTeardownTime.timeIntervalSince1970 > 0
            && Date().timeIntervalSince(lastTeardownTime) < 10

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.currentChannel?.id == channel.id else {
                self.log.log("Channel changed during debounce, aborting play for \(channel.name)", category: .player)
                return
            }
            self.startStream(for: channel)
        }
        pendingPlayWorkItem = workItem

        if needsDelay {
            log.log("Debouncing 1.5s before starting stream", category: .player)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
        } else {
            workItem.perform()
        }
    }

    private func startStream(for channel: Channel) {
        let media = VLCMedia(url: channel.streamURL)
        let cacheMs = Int(bufferDuration * 1000)
        log.log("VLC media options: network-caching=\(cacheMs)ms, live-caching=\(cacheMs)ms", category: .player)
        media.addOptions([
            "network-caching": cacheMs,
            "live-caching": cacheMs,
            "http-user-agent": "AdagioStream/1.0",
        ])

        media.delegate = self
        mediaPlayer.media = media
        mediaPlayer.audio?.volume = 100
        mediaPlayer.play()
        isActiveSession = true
        log.log("play() started: playerState=\(vlcStateName(mediaPlayer.state)), willPlay=\(mediaPlayer.willPlay)", category: .player)

        // Poll state as a reliable fallback since VLC delegate
        // fires on a background thread that can miss MainActor updates
        stateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.syncState()
            }
        }
    }

    // MARK: - Time-Shift Buffered Playback

    private func playBufferedFile(_ fileURL: URL, for channel: Channel) {
        log.log("playBufferedFile: \(fileURL.lastPathComponent) for \"\(channel.name)\"", category: .player)

        pendingPlayWorkItem?.cancel()
        pendingPlayWorkItem = nil
        interruptedChannel = nil
        lastLoggedVLCState = nil
        stateTimer?.invalidate()

        // Destroy old player
        let hadActiveMedia = mediaPlayer.media != nil || isActiveSession
        if hadActiveMedia {
            mediaPlayer.stop()
            mediaPlayer.media = nil
            mediaPlayer.delegate = nil
            mediaPlayer = VLCMediaPlayer()
            mediaPlayer.delegate = self
        }

        currentChannel = channel
        isPlayingBufferedFile = true
        bufferedChannel = channel
        currentBufferFileURL = fileURL
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

        stateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.syncState()
            }
        }
    }

    /// Skip buffered content and rejoin the live stream immediately.
    func skipToLive() {
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

    func pause() {
        log.log("pause() channel=\"\(currentChannel?.name ?? "nil")\"", category: .player)
        interruptedChannel = nil
        if let oldURL = currentBufferFileURL {
            timeShiftBuffer.deleteBufferFile(at: oldURL)
            currentBufferFileURL = nil
        }
        isPlayingBufferedFile = false
        bufferedChannel = nil
        timeShiftBuffer.cancelAndCleanup()
        isActiveSession = false
        stateTimer?.invalidate()
        stateTimer = nil
        if let start = listeningStartDate {
            accumulatedListeningTime += Date().timeIntervalSince(start)
            listeningStartDate = nil
        }
        mediaPlayer.stop()
        isPlaying = false
        isBuffering = false
        sxmService.stopPolling()
        updateNowPlayingInfo()
    }

    func resume() {
        let channelName = (currentChannel ?? lastPlayedChannel)?.name ?? "nil"
        log.log("resume() channel=\"\(channelName)\"", category: .player)
        guard let channel = currentChannel ?? lastPlayedChannel else {
            log.log("resume() aborted: no channel available", category: .player)
            return
        }
        play(channel: channel)
    }

    func togglePlayPause() {
        let now = Date()
        guard now.timeIntervalSince(lastToggleTime) > 0.5 else {
            log.log("togglePlayPause() debounced", category: .player)
            return
        }
        lastToggleTime = now
        log.log("togglePlayPause() isActive=\(isActiveSession)", category: .player)

        if isActiveSession {
            pause()
        } else {
            resume()
        }
    }

    func stop() {
        log.log("stop() channel=\"\(currentChannel?.name ?? "nil")\"", category: .player)
        // Note: do NOT clear interruptedChannel here — stop() is called
        // by the interruption handler after saving the channel to resume.
        // Only pause() and play() should clear it (explicit user actions).
        let wasPlayingBuffer = isPlayingBufferedFile
        if let oldURL = currentBufferFileURL {
            timeShiftBuffer.deleteBufferFile(at: oldURL)
            currentBufferFileURL = nil
        }
        isPlayingBufferedFile = false
        bufferedChannel = nil
        // Cancel time-shift if: explicit user stop (no interruptedChannel),
        // OR we were playing the buffer (old buffer is done, need fresh state).
        // Don't cancel when interrupting a live stream — capture is about to start.
        if wasPlayingBuffer || interruptedChannel == nil {
            timeShiftBuffer.cancelAndCleanup()
        }
        isActiveSession = false
        stateTimer?.invalidate()
        stateTimer = nil
        listeningStartDate = nil
        accumulatedListeningTime = 0
        listeningDuration = 0
        mediaPlayer.stop()
        mediaPlayer.media = nil
        lastPlayedChannel = currentChannel
        currentChannel = nil
        isPlaying = false
        isBuffering = false
        currentArtwork = nil
        sxmArtwork = nil
        sxmService.stopPolling()
        clearNowPlayingInfo()
    }

    func playNext() {
        let list = channels.isEmpty ? ProviderManager.shared.channels : channels
        guard !list.isEmpty,
              let current = currentChannel ?? lastPlayedChannel,
              let index = list.firstIndex(where: { $0.id == current.id }) else { return }
        channels = list
        let nextIndex = (index + 1) % list.count
        play(channel: list[nextIndex])
    }

    func playPrevious() {
        let list = channels.isEmpty ? ProviderManager.shared.channels : channels
        guard !list.isEmpty,
              let current = currentChannel ?? lastPlayedChannel,
              let index = list.firstIndex(where: { $0.id == current.id }) else { return }
        channels = list
        let prevIndex = (index - 1 + list.count) % list.count
        play(channel: list[prevIndex])
    }

    func updateBufferDuration(_ duration: TimeInterval) {
        bufferDuration = duration
    }

    // MARK: - VLCMediaPlayerDelegate

    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        Task { @MainActor in
            let newState = self.mediaPlayer.state
            let oldState = self.lastLoggedVLCState

            // Only log on actual state transitions to avoid flooding
            if newState != oldState {
                self.lastLoggedVLCState = newState
                self.logVLCTransition(from: oldState, to: newState)
            }
            self.syncState()
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

        log.log(details, category: .vlcState)
    }

    private func vlcStateName(_ state: VLCMediaPlayerState) -> String {
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

    nonisolated func mediaDidFinishParsing(_ aMedia: VLCMedia) {
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
            DebugLogger.shared.log("Media parsed: status=\(parsedName), tracks=\(tracks.count), url=\(aMedia.url?.absoluteString ?? "nil")", category: .vlcState)
            if parsed.rawValue == 2 || parsed.rawValue == 3 { // failed or timeout
                DebugLogger.shared.log("MEDIA PARSE FAILURE: This may explain why playback didn't start", category: .vlcState)
            }
        }
    }

    nonisolated func mediaMetaDataDidChange(_ aMedia: VLCMedia) {
        // Intentionally minimal — just note it happened
        DebugLogger.shared.log("Media metadata changed", category: .vlcState)
    }

    // MARK: - State Sync

    private func syncState() {
        guard isActiveSession else { return }

        let vlcIsPlaying = mediaPlayer.isPlaying
        let vlcState = mediaPlayer.state

        // VLC reports .buffering state and isPlaying=false continuously
        // for live streams even while audio is actively playing.
        // Use demux bitrate as a reliable indicator of actual playback.
        let hasDataFlow: Bool = {
            guard let media = mediaPlayer.media else { return false }
            let stats = media.statistics
            return stats.demuxBitrate > 0 || stats.inputBitrate > 0
        }()

        if vlcIsPlaying || vlcState == .playing {
            isPlaying = true
            isBuffering = false
            error = nil
        } else if hasDataFlow && (vlcState == .buffering || vlcState == .opening) {
            // VLC says buffering but data is flowing — audio is actually playing
            isPlaying = true
            isBuffering = false
            error = nil
        } else {
            switch vlcState {
            case .buffering, .opening:
                isBuffering = true
            case .paused:
                isPlaying = false
                isBuffering = false
            case .stopped:
                if currentChannel != nil {
                    isPlaying = false
                    isBuffering = false
                    if isActiveSession {
                        // Check if this is a server rejection (0 bytes read)
                        let bytesRead = mediaPlayer.media?.statistics.readBytes ?? 0
                        if bytesRead == 0 && channelChangeRetryCount < maxChannelChangeRetries {
                            channelChangeRetryCount += 1
                            let retryDelay = Double(channelChangeRetryCount) * 1.5
                            log.log("VLC stopped with 0 bytes (server likely rejected) — retry \(channelChangeRetryCount)/\(maxChannelChangeRetries) in \(retryDelay)s, channel=\"\(currentChannel?.name ?? "nil")\"", category: .vlcState)
                            isActiveSession = false
                            stateTimer?.invalidate()
                            stateTimer = nil
                            if let channel = currentChannel {
                                let workItem = DispatchWorkItem { [weak self] in
                                    guard let self, self.currentChannel?.id == channel.id else { return }
                                    self.log.log("Retrying channel \"\(channel.name)\" (attempt \(self.channelChangeRetryCount))", category: .player)
                                    self.mediaPlayer.stop()
                                    self.mediaPlayer.media = nil
                                    self.mediaPlayer.delegate = nil
                                    self.mediaPlayer = VLCMediaPlayer()
                                    self.mediaPlayer.delegate = self
                                    self.lastLoggedVLCState = nil
                                    self.isBuffering = true
                                    self.startStream(for: channel)
                                }
                                pendingPlayWorkItem = workItem
                                DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay, execute: workItem)
                            }
                        } else {
                            log.log("VLC stopped unexpectedly, channel=\"\(currentChannel?.name ?? "nil")\", bytesRead=\(bytesRead), retries=\(channelChangeRetryCount)", category: .vlcState)
                            isActiveSession = false
                            stateTimer?.invalidate()
                            stateTimer = nil
                            if channelChangeRetryCount >= maxChannelChangeRetries {
                                error = "Unable to connect — server may be limiting connections. Try again in a moment."
                            }
                        }
                    }
                }
            case .error:
                isPlaying = false
                isBuffering = false
                error = "Stream playback error"
                log.log("VLC ERROR state for channel=\"\(currentChannel?.name ?? "nil")\"", category: .vlcState)
            case .ended:
                isPlaying = false
                isBuffering = false
                if isPlayingBufferedFile, let channel = bufferedChannel {
                    // Clean up the buffer file we just finished playing
                    if let oldURL = currentBufferFileURL {
                        timeShiftBuffer.deleteBufferFile(at: oldURL)
                        currentBufferFileURL = nil
                    }

                    // Stop the continuation capture and check for a next buffer
                    let nextBuffer = timeShiftBuffer.stopCapture()
                    if let nextBuffer {
                        log.log("Buffer ended, chaining to next buffer for \"\(channel.name)\"", category: .player)
                        playBufferedFile(nextBuffer, for: channel)
                    } else {
                        log.log("Buffer ended, caught up to live for \"\(channel.name)\"", category: .player)
                        isPlayingBufferedFile = false
                        bufferedChannel = nil
                        timeShiftBuffer.cancelAndCleanup()
                        play(channel: channel)
                    }
                }
            default:
                break
            }
        }

        if let start = listeningStartDate {
            listeningDuration = accumulatedListeningTime + Date().timeIntervalSince(start)
        }

        updateStreamStats()
        updateNowPlayingInfo()
    }

    // MARK: - Stream Stats

    private func updateStreamStats() {
        guard currentChannel != nil else {
            statusText = ""
            streamBitrateKbps = 0
            return
        }

        if let media = mediaPlayer.media {
            let stats = media.statistics
            let currentKbps = Double(stats.demuxBitrate) * 1000

            if currentKbps > 1 {
                // Smooth toward the actual demux rate (EMA, ~5s window at 0.5s poll)
                if streamBitrateKbps < 1 {
                    streamBitrateKbps = currentKbps
                } else {
                    streamBitrateKbps = streamBitrateKbps * 0.8 + currentKbps * 0.2
                }
            }
        }

        if isPlayingBufferedFile {
            let duration = String(format: "%.0f", timeShiftBuffer.capturedDuration)
            statusText = "Catching up \u{00B7} \(duration)s behind"
        } else if isBuffering {
            statusText = "Buffering... (cache: \(Int(bufferDuration))s)"
        } else if isPlaying {
            if streamBitrateKbps > 1 {
                let formatted = streamBitrateKbps >= 1000
                    ? String(format: "%.1f Mbps", streamBitrateKbps / 1000)
                    : "\(Int(streamBitrateKbps)) kbps"
                statusText = "Live \u{00B7} \(formatted)"
            } else {
                statusText = "Live"
            }
        } else {
            statusText = ""
        }
    }

    // MARK: - Now Playing Info

    func refreshNowPlayingInfo() {
        updateNowPlayingInfo()
    }

    private func updateNowPlayingInfo() {
        guard let channel = currentChannel else { return }

        let title: String
        let artist: String
        let artwork: MPMediaItemArtwork?

        if let track = sxmService.currentTrack {
            title = track.title
            artist = track.artistDisplay
            artwork = sxmArtwork ?? currentArtwork
        } else {
            title = channel.name
            artist = channel.group
            artwork = currentArtwork
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPNowPlayingInfoPropertyIsLiveStream: !isPlayingBufferedFile,
            MPNowPlayingInfoPropertyPlaybackRate: (isPlaying || isBuffering) ? 1.0 : 0.0,
        ]

        if let artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        if isPlaying {
            center.playbackState = .playing
        } else if isBuffering {
            center.playbackState = .playing
        } else if currentChannel != nil {
            center.playbackState = .paused
        }
    }

    private func fetchSXMArtwork(url: URL, trackID: String) {
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { return }
            guard self.sxmService.currentTrack?.id == trackID else { return }
            self.sxmArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.updateNowPlayingInfo()
        }
    }

    private func fetchArtwork(for channel: Channel) {
        guard let logoURL = channel.logoURL else { return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: logoURL),
                  let image = UIImage(data: data) else { return }
            guard self.currentChannel?.id == channel.id else { return }
            self.currentArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.updateNowPlayingInfo()
        }
    }

    private func clearNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Remote Commands

    private func configureRemoteCommands() {
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

        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            DebugLogger.shared.log("Remote command: NEXT_TRACK", category: .remoteCommand)
            Task { @MainActor in self?.playNext() }
            return .success
        }

        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            DebugLogger.shared.log("Remote command: PREVIOUS_TRACK", category: .remoteCommand)
            Task { @MainActor in self?.playPrevious() }
            return .success
        }

        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.skipBackwardCommand.isEnabled = false
        commandCenter.seekForwardCommand.isEnabled = false
        commandCenter.seekBackwardCommand.isEnabled = false
        commandCenter.changePlaybackPositionCommand.isEnabled = false
    }
}

// MARK: - Call Observer

/// Logs phone call state changes for debugging CarPlay interruption issues.
final class CallObserverDelegate: NSObject, CXCallObserverDelegate {
    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        let state: String
        if call.hasEnded {
            state = "ENDED"
        } else if call.hasConnected {
            state = "CONNECTED"
        } else if call.isOutgoing {
            state = "OUTGOING_RINGING"
        } else {
            state = "INCOMING_RINGING"
        }
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.map { "\($0.portName) (\($0.portType.rawValue))" }.joined(separator: ", ")
        let isCarPlay = session.currentRoute.outputs.contains { $0.portType == .carAudio }
        DebugLogger.shared.log("Call \(state): onHold=\(call.isOnHold), carplay=\(isCarPlay), outputs=[\(outputs)], otherAudio=\(session.isOtherAudioPlaying), mode=\(session.mode.rawValue)", category: .call)
    }
}
