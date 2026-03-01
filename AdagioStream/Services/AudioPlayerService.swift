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

    private let mediaPlayer = VLCMediaPlayer()
    private let callObserver = CXCallObserver()
    private let callDelegate = CallObserverDelegate()
    private var listeningStartDate: Date?
    private var accumulatedListeningTime: TimeInterval = 0
    private var stateTimer: Timer?
    private var currentArtwork: MPMediaItemArtwork?
    private var lastPlayedChannel: Channel?
    private var wasPlayingBeforeInterruption = false
    private var isActiveSession = false
    private var lastToggleTime: Date = .distantPast
    private var interruptionRecoveryTask: Task<Void, Never>?
    private var lastLoggedVLCState: VLCMediaPlayerState?

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
                // Use isActiveSession rather than isPlaying/isBuffering since VLC's
                // state timer may have already cleared those by the time this runs
                wasPlayingBeforeInterruption = isActiveSession
                self.log.log("Interruption BEGAN: wasPlaying=\(self.wasPlayingBeforeInterruption), isActive=\(self.isActiveSession), vlcState=\(self.mediaPlayer.state.rawValue)", category: .interruption)
                self.logAudioSessionSnapshot("interruption.began")

                // Start a recovery watchdog: if .ended never fires (common with
                // CarPlay Siri announcements), recover automatically after 8s
                interruptionRecoveryTask?.cancel()
                if wasPlayingBeforeInterruption {
                    self.log.log("Starting 8s recovery watchdog", category: .interruption)
                    interruptionRecoveryTask = Task {
                        try? await Task.sleep(for: .seconds(8))
                        guard !Task.isCancelled, wasPlayingBeforeInterruption else {
                            DebugLogger.shared.log("Recovery watchdog: cancelled or not needed", category: .interruption)
                            return
                        }

                        DebugLogger.shared.log("Recovery watchdog: .ended never fired, checking other audio", category: .interruption)
                        await self.logAudioSessionSnapshot("watchdog.fired")

                        // If another audio session is still active (phone call,
                        // long Siri response), poll until it finishes rather than
                        // resuming over it.  For phone calls the .ended notification
                        // will cancel this task; the loop is a safety net.
                        var pollCount = 0
                        for _ in 0..<60 {
                            guard !Task.isCancelled, wasPlayingBeforeInterruption else { return }
                            guard AVAudioSession.sharedInstance().isOtherAudioPlaying else { break }
                            pollCount += 1
                            try? await Task.sleep(for: .seconds(2))
                        }
                        guard !Task.isCancelled, wasPlayingBeforeInterruption else { return }

                        DebugLogger.shared.log("Recovery watchdog: resuming after \(pollCount) polls", category: .interruption)
                        wasPlayingBeforeInterruption = false
                        reactivateSessionAndResume()
                    }
                }

            case .ended:
                let options = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let shouldResume = AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
                self.log.log("Interruption ENDED: wasPlaying=\(self.wasPlayingBeforeInterruption), shouldResume=\(shouldResume)", category: .interruption)
                self.logAudioSessionSnapshot("interruption.ended")

                interruptionRecoveryTask?.cancel()
                guard wasPlayingBeforeInterruption else {
                    self.log.log("Interruption ended but was not playing, skipping resume", category: .interruption)
                    interruptionRecoveryTask = nil
                    return
                }
                wasPlayingBeforeInterruption = false

                // Delay to let the audio route settle (CarPlay route transitions
                // need time to switch back from phone/Siri to media output).
                // Store in interruptionRecoveryTask so a new .began cancels it.
                self.log.log("Scheduling 500ms delayed resume", category: .interruption)
                interruptionRecoveryTask = Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else {
                        DebugLogger.shared.log("Delayed resume cancelled", category: .interruption)
                        return
                    }
                    DebugLogger.shared.log("Executing delayed resume", category: .interruption)
                    reactivateSessionAndResume()
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

    private func reactivateSessionAndResume() {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.map { "\($0.portName) (\($0.portType.rawValue))" }.joined(separator: ", ")
        log.log("reactivateSessionAndResume: outputs=[\(outputs)]", category: .audioSession)

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

        resume()
    }

    // MARK: - Playback

    func play(channel: Channel) {
        log.log("play() channel=\"\(channel.name)\" group=\"\(channel.group)\" url=\(channel.streamURL.absoluteString)", category: .player)
        interruptionRecoveryTask?.cancel()
        interruptionRecoveryTask = nil
        lastLoggedVLCState = nil
        stateTimer?.invalidate()

        // Fully tear down the previous stream before starting a new one.
        // VLC's stop() is async internally — the HTTP connection lingers
        // briefly.  Xtream Codes servers enforce a connection limit per
        // account and will 403 if the old stream is still open when the
        // new one connects.  Nil-ing out the media forces VLC to release
        // the old connection, and the short delay lets the TCP teardown
        // complete before we open a new one.
        let hadPreviousStream = mediaPlayer.media != nil
        mediaPlayer.stop()
        mediaPlayer.media = nil

        let channelChanged = currentChannel?.id != channel.id
        currentChannel = channel
        isBuffering = true
        isPlaying = false
        error = nil
        streamBitrateKbps = 0
        statusText = ""
        if channelChanged {
            accumulatedListeningTime = 0
            listeningDuration = 0
            currentArtwork = nil
            fetchArtwork(for: channel)
        }
        listeningStartDate = Date()
        updateNowPlayingInfo()

        let startBlock = { [weak self] in
            guard let self else { return }
            let media = VLCMedia(url: channel.streamURL)
            let cacheMs = Int(self.bufferDuration * 1000)
            self.log.log("VLC media options: network-caching=\(cacheMs)ms, live-caching=\(cacheMs)ms", category: .player)
            media.addOptions([
                "network-caching": cacheMs,
                "live-caching": cacheMs,
                "http-user-agent": "AdagioStream/1.0",
            ])

            media.delegate = self
            self.mediaPlayer.media = media
            self.mediaPlayer.audio?.volume = 100
            self.mediaPlayer.play()
            self.isActiveSession = true
            self.log.log("play() started: playerState=\(self.vlcStateName(self.mediaPlayer.state)), willPlay=\(self.mediaPlayer.willPlay)", category: .player)

            // Poll state as a reliable fallback since VLC delegate
            // fires on a background thread that can miss MainActor updates
            self.stateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.syncState()
                }
            }
        }

        if hadPreviousStream {
            // Give the old connection time to close before opening a new one
            log.log("Waiting for previous stream teardown before starting new stream", category: .player)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: startBlock)
        } else {
            startBlock()
        }
    }

    func pause() {
        log.log("pause() channel=\"\(currentChannel?.name ?? "nil")\"", category: .player)
        interruptionRecoveryTask?.cancel()
        interruptionRecoveryTask = nil
        wasPlayingBeforeInterruption = false
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
        interruptionRecoveryTask?.cancel()
        interruptionRecoveryTask = nil
        wasPlayingBeforeInterruption = false
        isActiveSession = false
        stateTimer?.invalidate()
        stateTimer = nil
        listeningStartDate = nil
        accumulatedListeningTime = 0
        listeningDuration = 0
        mediaPlayer.stop()
        lastPlayedChannel = currentChannel
        currentChannel = nil
        isPlaying = false
        isBuffering = false
        currentArtwork = nil
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
                    // Log when VLC stops unexpectedly while we expect playback
                    if isActiveSession {
                        log.log("VLC stopped unexpectedly while session active, channel=\"\(currentChannel?.name ?? "nil")\"", category: .vlcState)
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
            let demux = Double(stats.demuxBitrate)
            let input = Double(stats.inputBitrate)
            let currentKbps = max(demux, input) * 1000

            if currentKbps > 1 {
                // Keep the highest observed bitrate as the stable value
                // since instantaneous rates dip when buffers are full
                if currentKbps > streamBitrateKbps {
                    streamBitrateKbps = currentKbps
                }
            }
        }

        if isBuffering {
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

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: channel.name,
            MPMediaItemPropertyArtist: channel.group,
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: (isPlaying || isBuffering) ? 1.0 : 0.0,
        ]

        if let artwork = currentArtwork {
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
