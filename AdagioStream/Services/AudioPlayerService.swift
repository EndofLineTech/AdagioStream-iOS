import AVFoundation
import Combine
import MediaPlayer
import SwiftUI
import VLCKitSPM

@MainActor
final class AudioPlayerService: NSObject, ObservableObject, VLCMediaPlayerDelegate {
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
    private var listeningStartDate: Date?
    private var accumulatedListeningTime: TimeInterval = 0
    private var stateTimer: Timer?
    private var currentArtwork: MPMediaItemArtwork?
    private var lastPlayedChannel: Channel?
    private var wasPlayingBeforeInterruption = false
    private var isActiveSession = false
    private var lastToggleTime: Date = .distantPast
    private var interruptionRecoveryTask: Task<Void, Never>?

    var channels: [Channel] = []
    var bufferDuration: TimeInterval = Constants.defaultBufferDuration

    private override init() {
        super.init()
        log.log("AudioPlayerService init", category: .player)
        mediaPlayer.delegate = self
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
    }

    @objc nonisolated private func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.map { "\($0.portName) (\($0.portType.rawValue))" }.joined(separator: ", ")
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
        DebugLogger.shared.log("Route change: reason=\(reasonName), outputs=[\(outputs)]", category: .audioSession)
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
        mediaPlayer.stop()
        stateTimer?.invalidate()

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

        let media = VLCMedia(url: channel.streamURL)
        let cacheMs = Int(bufferDuration * 1000)
        log.log("VLC media options: network-caching=\(cacheMs)ms, live-caching=\(cacheMs)ms", category: .player)
        media.addOptions([
            "network-caching": cacheMs,
            "live-caching": cacheMs,
            "http-user-agent": "AdagioStream/1.0",
        ])

        mediaPlayer.media = media
        mediaPlayer.audio?.volume = 100
        mediaPlayer.play()
        isActiveSession = true
        updateNowPlayingInfo()

        // Poll state as a reliable fallback since VLC delegate
        // fires on a background thread that can miss MainActor updates
        stateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.syncState()
            }
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
            DebugLogger.shared.log("VLC delegate stateChanged: state=\(self.mediaPlayer.state.rawValue), isPlaying=\(self.mediaPlayer.isPlaying)", category: .vlcState)
            self.syncState()
        }
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
