// AudioPlayerService is iOS-only per Phase 0 G2. The whole file body —
// including the imports — is gated with `#if os(iOS)` so the tvOS
// build sees no symbol. tvOS gets its own audio service in Phase 1.

#if os(iOS)
import AVFoundation
import Combine
import MediaPlayer
import Network
import SwiftUI
@preconcurrency import VLCKitSPM

@MainActor
public final class AudioPlayerService: NSObject, ObservableObject, VLCMediaPlayerDelegate, VLCMediaDelegate {
    public static let shared = AudioPlayerService()
    private let log = DebugLogger.shared

    @Published public var currentChannel: Channel?
    @Published public var isPlaying = false
    @Published public var isBuffering = false
    @Published public var error: String?
    @Published public var streamBitrateKbps: Double = 0
    @Published public var statusText: String = ""
    @Published public var streamTitle: String?
    @Published public var streamArtist: String?
    /// Use `listeningStartDate` and `accumulatedListeningTime` to compute duration in views.
    public private(set) var listeningStartDate: Date?
    public private(set) var accumulatedListeningTime: TimeInterval = 0

    public let timeShiftBuffer = TimeShiftBufferService.shared
    public let sxmService = SXMMetadataService.shared

    private var mediaPlayer = VLCMediaPlayer()
    private var sxmCancellable: AnyCancellable?
    private var espnCancellable: AnyCancellable?
    private var stateTimer: Timer?
    private let fastPollInterval: TimeInterval = 0.5
    private let slowPollInterval: TimeInterval = 3.0
    private let backgroundPollInterval: TimeInterval = 10.0
    private var currentPollInterval: TimeInterval = 0.5
    private var isInBackground = false
    private var currentArtwork: MPMediaItemArtwork?
    private var sxmArtwork: MPMediaItemArtwork?
    private var lastPlayedChannel: Channel?
    private var interruptedChannel: Channel?
    private var isActiveSession = false
    private var lastToggleTime: Date = .distantPast
    private var lastLoggedVLCState: VLCMediaPlayerState?
    private var channelChangeRetryCount = 0
    private var vlcZeroByteRetryCount = 0
    private let maxVLCZeroByteRetries = 5
    private var streamProbeTask: URLSessionDataTask?
    private var probeStartTime: Date?
    private let probeTimeout: TimeInterval = 45
    private var lastProbeHTTPStatus: Int?
    private var pendingPlayWorkItem: DispatchWorkItem?
    private var channelNameOverlayActive = false
    private var channelNameOverlayWorkItem: DispatchWorkItem?
    private var lastTeardownTime: Date = .distantPast
    private var isPlayingBufferedFile = false
    private var streamStartTime: Date?
    private var wasAwaitingInitialBuffer = false
    private var hasReceivedData = false
    private var isReducedBufferRetry = false
    private let bufferingTimeoutInterval: TimeInterval = 20
    private let reducedBufferDuration: TimeInterval = 3
    /// Last decoded audio frame count observed with active data flow.
    private var lastActiveDecodedAudio: Int32 = 0
    /// Tracked for detecting mid-stream buffer loss (audio blips).
    private var lastLoggedLostAudioBuffers: Int32 = 0
    private var lastLoggedDiscontinuity: Int32 = 0
    /// When data flow was last seen (demux or input bitrate > 0).
    private var lastDataFlowTime: Date?
    /// How long data flow can be absent before triggering auto-reconnect.
    private let dataFlowStaleTimeout: TimeInterval = 8
    private var bufferingBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var lastNowPlayingTitle: String?
    private var lastNowPlayingArtist: String?
    private var lastNowPlayingIsLive: Bool?
    private var lastNowPlayingRate: Double?
    private var lastNowPlayingState: MPNowPlayingPlaybackState?
    private var lastNowPlayingArtwork: MPMediaItemArtwork?
    private var bufferedChannel: Channel?
    private var currentBufferFileURL: URL?
    private var interruptionTime: Date?
    private var bufferPlaybackStartedAt: Date?
    /// True while an audio session interruption is active and VLC is being
    /// kept alive (short-interruption path).  Suppresses syncState reactions.
    private var isRidingOutInterruption = false
    /// Fires when a short interruption exceeds bufferDuration, falling back
    /// to the old stop-and-capture path.
    private var interruptionFallbackWorkItem: DispatchWorkItem?

    private var pathMonitor: NWPathMonitor?
    private let pathMonitorQueue = DispatchQueue(label: "com.adagiostream.pathmonitor")
    private var lastPathStatus: NWPath.Status?
    private var lastPrimaryInterface: NWInterface.InterfaceType?
    private var lastPathReconnectTime: Date = .distantPast
    /// Minimum interval between path-monitor-triggered reconnects.  A subway
    /// or tower handoff can fire several path events in quick succession;
    /// without a cooldown we'd tear down and rebuild the player repeatedly.
    private let pathReconnectCooldown: TimeInterval = 5

    public var channels: [Channel] = []
    public var bufferDuration: TimeInterval = Constants.defaultBufferDuration
    public var artworkDisplayMode: ArtworkDisplayMode = .coverArt

    /// Run `block` and log how long it took.  Used to stamp every VLC
    /// teardown call so a future main-thread stall leaves an unambiguous
    /// fingerprint: the 0x8BADF00D scene-update watchdog gives us 10 s
    /// before SIGKILL, and without per-call timing we cannot tell from the
    /// log alone which call burned the budget.
    @discardableResult
    private func timed<T>(_ name: String, _ block: () -> T) -> T {
        let start = Date()
        let result = block()
        let elapsedMs = Int((Date().timeIntervalSince(start) * 1000).rounded())
        log.log("\(name) elapsed=\(elapsedMs)ms", category: .player)
        return result
    }

    /// Replace the current VLCMediaPlayer with a fresh instance, retiring the
    /// old one so that its `libvlc_media_player_destroy` (which calls
    /// `pthread_join` on VLC's internal threads) runs on a background queue
    /// instead of blocking the main thread.  Without this, a stalled network
    /// read in VLC's stream thread can block the join for >10 s, triggering
    /// the iOS 0x8BADF00D watchdog kill.
    ///
    /// - Parameter options: VLC instance-level options (e.g. `--network-caching=8000`).
    ///   Caching options MUST be set here — VLCKit's per-media `addOptions` uses
    ///   `libvlc_media_add_option` which silently rejects `network-caching` and
    ///   `live-caching` as "unsafe" options.  Instance-level options are always trusted.
    private func retirePlayer(options: [String]? = nil) {
        let old = mediaPlayer
        // Detach the media input *before* stop().  stop() synchronously
        // drains VLC's input/decoder threads; if the input thread is sitting
        // in poll() on a stalled socket, stop() inherits that block.
        // Clearing media first signals the input layer to exit so stop() has
        // nothing left to wait on.  Same logic for the delegate — clear it
        // before stop() so no late VLC callbacks land on a half-torn player.
        timed("retirePlayer: old.media=nil") { old.media = nil }
        timed("retirePlayer: old.delegate=nil") { old.delegate = nil }
        timed("retirePlayer: old.stop()") { old.stop() }
        timed("retirePlayer: new VLCMediaPlayer") {
            if let options {
                mediaPlayer = VLCMediaPlayer(options: options)
            } else {
                mediaPlayer = VLCMediaPlayer()
            }
        }
        mediaPlayer.delegate = self
        // Release on a background thread so pthread_join can't block main.
        // The closure strong-captures `old`; the actual dealloc runs when the
        // closure exits.  Log on entry and exit so we can confirm the path
        // executed and bound how long the dealloc itself blocked the utility
        // queue (which is harmless — main is what matters for the watchdog).
        DispatchQueue.global(qos: .utility).async { @Sendable [old] in
            let start = Date()
            DebugLogger.shared.log("retirePlayer: utility-queue dispose entered", category: .player)
            _ = old
            // dealloc fires here as the closure scope exits — measured by the
            // gap between this log and the next teardown log on this queue.
            let elapsedMs = Int((Date().timeIntervalSince(start) * 1000).rounded())
            DebugLogger.shared.log("retirePlayer: utility-queue dispose pre-exit elapsed=\(elapsedMs)ms", category: .player)
        }
    }

    private override init() {
        super.init()
        log.log("AudioPlayerService init", category: .player)
        mediaPlayer.delegate = self
        configureAudioSession()
        configureRemoteCommands()
        configureNetworkPathMonitor()
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

        espnCancellable = ESPNScoreService.shared.$gamesByChannel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateNowPlayingInfo()
            }
    }

    // MARK: - Audio Session

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
            try session.setActive(true)
            log.log("Audio session configured: category=playback, policy=longFormAudio", category: .audioSession)
        } catch {
            log.log("Audio session config FAILED: \(error.localizedDescription)", category: .audioSession)
            self.error = "Failed to configure audio session: \(error.localizedDescription)"
        }
        // Note: the AVAudioEngine (AudioOutput.shared) is started
        // lazily inside startStream(), not here.  Starting it during
        // AudioPlayerService.init causes the unit-test process to
        // deadlock on teardown because the test environment has no
        // valid audio session for the engine to associate with.

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

        // Route changes can wake the app from suspension — check for any
        // buffering timeouts that expired while the process was suspended.
        Task { @MainActor in
            self.syncState()
        }
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

                // Keep VLC alive during short interruptions — its internal
                // network-caching buffer (typically 8s) bridges the gap
                // without needing a cold restart.  Only fall back to
                // stop-and-capture if the interruption exceeds bufferDuration.
                if self.isActiveSession, let channel = self.currentChannel {
                    self.interruptedChannel = channel
                    self.isRidingOutInterruption = true
                    let currentBitrate = self.streamBitrateKbps
                    self.log.log("Riding out interruption for \"\(channel.name)\" (VLC cache \(Int(self.bufferDuration))s)", category: .interruption)

                    // Safety net: if the interruption runs longer than VLC's
                    // cache, fall back to the old stop+capture path.
                    let interruptionStarted = Date()
                    let fallback = DispatchWorkItem { [weak self] in
                        guard let self, self.isRidingOutInterruption,
                              self.interruptedChannel?.id == channel.id else { return }
                        let elapsed = Date().timeIntervalSince(interruptionStarted)
                        self.log.log("Interruption exceeded VLC cache (\(Int(self.bufferDuration))s) — elapsed \(Int(elapsed))s, falling back to stop+capture", category: .interruption)
                        self.isRidingOutInterruption = false
                        self.stop()
                        self.interruptedChannel = channel
                        // Only attempt time-shift capture if the interruption
                        // is recent enough that the stream URL is likely still
                        // connectable.  If the app was suspended for minutes,
                        // the server has long closed the connection — capturing
                        // would just get 0 bytes.
                        if elapsed <= 30 {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                guard self.interruptedChannel?.id == channel.id else { return }
                                self.timeShiftBuffer.startCapture(for: channel, estimatedBitrateKbps: currentBitrate)
                            }
                        } else {
                            self.log.log("Skipping time-shift capture — interruption too stale (\(Int(elapsed))s)", category: .interruption)
                        }
                    }
                    self.interruptionFallbackWorkItem = fallback
                    DispatchQueue.main.asyncAfter(deadline: .now() + self.bufferDuration, execute: fallback)
                }

            case .ended:
                let options = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let shouldResume = AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
                self.log.log("Interruption ENDED: interruptedChannel=\"\(self.interruptedChannel?.name ?? "nil")\", shouldResume=\(shouldResume), ridingOut=\(self.isRidingOutInterruption)", category: .interruption)
                self.logAudioSessionSnapshot("interruption.ended")

                // Cancel the fallback timer — interruption ended in time
                self.interruptionFallbackWorkItem?.cancel()
                self.interruptionFallbackWorkItem = nil

                guard let channel = self.interruptedChannel else {
                    self.log.log("Interruption ended but no interrupted channel, skipping resume", category: .interruption)
                    self.isRidingOutInterruption = false
                    return
                }

                if self.isRidingOutInterruption {
                    // Short interruption — VLC stayed alive with its internal cache.
                    // Just reactivate the audio session so VLC can output again.
                    self.isRidingOutInterruption = false
                    self.interruptedChannel = nil
                    self.log.log("Short interruption ended — reactivating audio session for \"\(channel.name)\"", category: .interruption)

                    // Delay to let the audio route settle (CarPlay route transitions
                    // need time to switch back from phone/Siri to media output).
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        let session = AVAudioSession.sharedInstance()
                        do {
                            try session.setActive(false, options: .notifyOthersOnDeactivation)
                            self.log.log("Session deactivated OK (short interruption)", category: .audioSession)
                        } catch {
                            self.log.log("Session deactivate FAILED (short interruption): \(error.localizedDescription)", category: .audioSession)
                        }
                        do {
                            try session.setActive(true)
                            self.log.log("Session reactivated OK (short interruption)", category: .audioSession)
                        } catch {
                            self.log.log("Session reactivate FAILED (short interruption): \(error.localizedDescription)", category: .audioSession)
                        }

                        // Check if VLC survived the interruption
                        let vlcAlive = self.isActiveSession && (self.mediaPlayer.isPlaying || self.mediaPlayer.state == .buffering || self.mediaPlayer.state == .opening)
                        self.log.log("VLC post-interruption: alive=\(vlcAlive), state=\(self.vlcStateName(self.mediaPlayer.state)), isPlaying=\(self.mediaPlayer.isPlaying)", category: .interruption)

                        if vlcAlive {
                            // VLC is fine — nothing else to do, audio resumes from cache
                            self.log.log("VLC survived interruption — seamless resume", category: .interruption)
                        } else {
                            // VLC died during the interruption — cold restart
                            self.log.log("VLC died during interruption — cold restarting \"\(channel.name)\"", category: .interruption)
                            self.play(channel: channel)
                        }
                    }
                } else {
                    // Long interruption — fallback already stopped VLC and started capture.
                    // Use the existing time-shift buffer path.
                    self.interruptedChannel = nil

                    let bufferFileURL = self.timeShiftBuffer.stopCapture()
                    self.log.log("Time-shift buffer: \(bufferFileURL != nil ? "available" : "none")", category: .interruption)

                    self.log.log("Scheduling 500ms delayed restart for \"\(channel.name)\"", category: .interruption)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.reactivateAndPlay(channel: channel, bufferFileURL: bufferFileURL)
                    }
                }

            @unknown default:
                self.log.log("Interruption UNKNOWN type: \(typeValue)", category: .interruption)
                break
            }
        }
    }

    // MARK: - Network Path Monitor

    /// Human-readable summary of the last observed network path, for debug
    /// snapshots.  Returns "unknown" if the monitor has not fired yet.
    public var networkPathSummary: String {
        guard let status = lastPathStatus else { return "unknown" }
        let interfaceName = lastPrimaryInterface.map(self.interfaceName) ?? "none"
        return "\(pathStatusName(status)) via \(interfaceName)"
    }

    /// Watches for network path transitions (Wi-Fi <-> cellular, online/offline)
    /// and forces a player rebuild when the underlying interface changes.
    /// VLC's own `--http-reconnect` handles connection-level drops but won't
    /// recover an HTTP socket bound to a now-dead Wi-Fi interface.
    private func configureNetworkPathMonitor() {
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            // NWPathMonitor invokes the handler on its own queue; hop to the
            // MainActor since we touch @MainActor state (currentChannel, etc.).
            Task { @MainActor [weak self] in
                self?.handlePathUpdate(path)
            }
        }
        monitor.start(queue: pathMonitorQueue)
    }

    private func handlePathUpdate(_ path: NWPath) {
        let primary = primaryInterfaceType(for: path)
        let primaryName = primary.map(interfaceName) ?? "none"
        let statusName = pathStatusName(path.status)

        // First fire after start() — record state, don't treat as a transition.
        guard let previousStatus = lastPathStatus else {
            lastPathStatus = path.status
            lastPrimaryInterface = primary
            log.log("Path monitor initial: status=\(statusName), primary=\(primaryName), expensive=\(path.isExpensive), constrained=\(path.isConstrained)", category: .player)
            return
        }

        let statusBecameSatisfied = previousStatus != .satisfied && path.status == .satisfied
        let previousPrimary = lastPrimaryInterface
        let interfaceChanged = path.status == .satisfied
            && previousPrimary != nil
            && primary != nil
            && primary != previousPrimary

        lastPathStatus = path.status
        lastPrimaryInterface = primary

        guard statusBecameSatisfied || interfaceChanged else { return }

        let previousPrimaryName = previousPrimary.map(interfaceName) ?? "none"
        let reason = statusBecameSatisfied
            ? "network came back (\(pathStatusName(previousStatus)) -> \(statusName))"
            : "primary interface changed (\(previousPrimaryName) -> \(primaryName))"
        log.log("Path transition: \(reason), expensive=\(path.isExpensive), constrained=\(path.isConstrained)", category: .player)

        guard let channel = currentChannel else { return }

        let elapsed = Date().timeIntervalSince(lastPathReconnectTime)
        if elapsed < pathReconnectCooldown {
            log.log("Path-driven reconnect suppressed — \(String(format: "%.1f", elapsed))s since last (cooldown \(Int(pathReconnectCooldown))s)", category: .player)
            return
        }

        log.log("Path-driven reconnect for \"\(channel.name)\" — \(reason)", category: .player)
        lastPathReconnectTime = Date()
        // play(channel:) early-exits when the channel matches and the session
        // is active.  Clear the flag so the full teardown/restart runs.
        isActiveSession = false
        play(channel: channel)
    }

    private func primaryInterfaceType(for path: NWPath) -> NWInterface.InterfaceType? {
        for type in [NWInterface.InterfaceType.wifi, .cellular, .wiredEthernet, .loopback, .other] {
            if path.usesInterfaceType(type) { return type }
        }
        return nil
    }

    private func interfaceName(_ type: NWInterface.InterfaceType) -> String {
        switch type {
        case .wifi: return "wifi"
        case .cellular: return "cellular"
        case .wiredEthernet: return "ethernet"
        case .loopback: return "loopback"
        case .other: return "other"
        @unknown default: return "unknown"
        }
    }

    private func pathStatusName(_ status: NWPath.Status) -> String {
        switch status {
        case .satisfied: return "satisfied"
        case .unsatisfied: return "unsatisfied"
        case .requiresConnection: return "requiresConnection"
        @unknown default: return "unknown"
        }
    }

    private func logAudioSessionSnapshot(_ context: String) {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.map { "\($0.portName) (\($0.portType.rawValue))" }.joined(separator: ", ")
        let inputs = session.currentRoute.inputs.map { "\($0.portName) (\($0.portType.rawValue))" }.joined(separator: ", ")
        let isCarPlay = session.currentRoute.outputs.contains { $0.portType == .carAudio }
        log.log("Session[\(context)]: cat=\(session.category.rawValue), mode=\(session.mode.rawValue), otherAudio=\(session.isOtherAudioPlaying), silenceHint=\(session.secondaryAudioShouldBeSilencedHint), carplay=\(isCarPlay), outputs=[\(outputs)], inputs=[\(inputs)]", category: .audioSession)
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

    public func play(channel: Channel) {
        // Don't tear down an active stream to restart the same channel.
        // During CarPlay reconnect, multiple PLAY commands and channel
        // selections can fire within seconds — each would needlessly
        // destroy and recreate the VLC player for no benefit.
        if channel.id == currentChannel?.id, isActiveSession {
            log.log("play() skipped: \"\(channel.name)\" already active", category: .player)
            return
        }

        log.log("play() channel=\"\(channel.name)\" group=\"\(channel.group)\" url=\(channel.streamURL.redactedForLog)", category: .player)

        // Cancel any pending stream start from a previous rapid channel tap
        pendingPlayWorkItem?.cancel()
        pendingPlayWorkItem = nil
        streamProbeTask?.cancel()
        streamProbeTask = nil
        probeStartTime = nil
        interruptedChannel = nil
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

        // Destroy the old VLCMediaPlayer entirely and create a fresh one.
        // Stop the current player so Xtream Codes' per-account connection
        // limit isn't hit when the new stream opens.  Don't replace the
        // VLCMediaPlayer here — startStream() will call retirePlayer(options:)
        // with the correct caching args.  Creating an intermediate player
        // without options poisons VLCKit's shared VLCLibrary instance,
        // causing all subsequent players to lose their caching settings.
        let hadActiveMedia = mediaPlayer.media != nil || isActiveSession
        let otherPlayingBeforeStop = AVAudioSession.sharedInstance().isOtherAudioPlaying
        log.log("play() entry: otherAudio=\(otherPlayingBeforeStop), hadActiveMedia=\(hadActiveMedia)", category: .audioSession)
        if hadActiveMedia {
            log.log("Stopping old VLCMediaPlayer to release connection", category: .player)
            timed("play(): mediaPlayer.stop()") { mediaPlayer.stop() }
            timed("play(): mediaPlayer.media=nil") { mediaPlayer.media = nil }
            // Drop whatever's still queued from the old stream so the
            // tail of channel A doesn't leak into channel B's first
            // moments through our ring buffer.  The AVAudioSourceNode
            // render block will see an empty buffer and emit silence
            // until the new stream's first play_cb arrives.
            VLCAudioCallbackBridge.flushBuffer()
            lastTeardownTime = Date()
            let otherPlayingAfterStop = AVAudioSession.sharedInstance().isOtherAudioPlaying
            log.log("play() post-stop: otherAudio=\(otherPlayingAfterStop), droppedFrames=\(VLCAudioCallbackBridge.droppedFrameCount)", category: .audioSession)
        }

        // Assert session ownership BEFORE the debounce timer.  Previously
        // this dance ran inside startStream(), so a channel change with
        // needsDelay=true left a ~1.5s window between mediaPlayer.stop()
        // (audio goes silent) and setActive(false)+setActive(true) (formal
        // takeover).  During that gap iOS would auto-resume the previously
        // interrupted app (Apple Music), which then got kicked off again
        // when the deferred setActive(false) fired — producing the
        // "briefly plays then stops" symptom on every channel change.
        assertSessionOwnership(context: "play(): pre-debounce takeover")

        let channelChanged = currentChannel?.id != channel.id
        currentChannel = channel
        UserDefaults.standard.set(channel.id, forKey: "lastPlayedChannelID")
        isActiveSession = false
        isBuffering = true
        isPlaying = false
        error = nil
        streamBitrateKbps = 0
        statusText = ""
        streamTitle = nil
        streamArtist = nil
        vlcZeroByteRetryCount = 0
        if channelChanged {
            channelChangeRetryCount = 0
            isReducedBufferRetry = false
            accumulatedListeningTime = 0
            currentArtwork = nil
            fetchArtwork(for: channel)
            // Show channel name briefly on the Now Playing screen so the user
            // knows which station they switched to (especially useful for
            // steering-wheel channel changes on CarPlay).
            channelNameOverlayWorkItem?.cancel()
            channelNameOverlayActive = true
            let overlayWork = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.channelNameOverlayActive = false
                self.updateNowPlayingInfo()
            }
            channelNameOverlayWorkItem = overlayWork
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: overlayWork)
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
            let otherNow = AVAudioSession.sharedInstance().isOtherAudioPlaying
            self.log.log("startStream entry: otherAudio=\(otherNow)", category: .audioSession)
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

    /// Deactivate→reactivate the session so iOS formally hands audio focus
    /// to Adagio.  A bare setActive(true) is a no-op when the session is
    /// already active, which leaves remote-command registration with
    /// whichever app held focus previously — steering-wheel next/prev then
    /// routes there instead of us.  Only runs the deactivate step when
    /// another app currently holds focus; otherwise this is a cheap no-op.
    @discardableResult
    private func assertSessionOwnership(context: String) -> Bool {
        let session = AVAudioSession.sharedInstance()
        let otherPlaying = session.isOtherAudioPlaying
        do {
            if otherPlaying {
                try session.setActive(false, options: .notifyOthersOnDeactivation)
                log.log("\(context): session deactivated to take over from other app", category: .audioSession)
            }
            try session.setActive(true)
            log.log("\(context): session active (otherWasPlaying=\(otherPlaying))", category: .audioSession)
            return otherPlaying
        } catch {
            log.log("\(context): session takeover FAILED: \(error.localizedDescription)", category: .audioSession)
            return false
        }
    }

    /// End any active background task requested for buffering timeout.
    private func endBufferingBackgroundTask() {
        if bufferingBackgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(bufferingBackgroundTaskID)
            bufferingBackgroundTaskID = .invalid
        }
    }

    private func startStream(for channel: Channel) {
        streamStartTime = Date()
        wasAwaitingInitialBuffer = false
        hasReceivedData = false
        lastDataFlowTime = nil
        lastActiveDecodedAudio = 0
        lastLoggedLostAudioBuffers = 0
        lastLoggedDiscontinuity = 0

        // Ensure the audio session is active before VLC connects.
        // After CarPlay disconnects, iOS fires interruption .began but
        // never sends .ended — leaving the session in an indeterminate
        // state.  Without this, VLC can stall (20s timeout) or do a
        // false-start play→buffering cycle.
        if isRidingOutInterruption {
            log.log("Clearing stale interruption state before stream start", category: .audioSession)
            isRidingOutInterruption = false
            interruptedChannel = nil
            interruptionFallbackWorkItem?.cancel()
            interruptionFallbackWorkItem = nil
        }
        // Belt-and-braces: play() already asserted ownership before the
        // debounce timer.  This handles the retry paths that call
        // startStream() directly (reconnect / channel-change retry).
        // When play() already took over, isOtherAudioPlaying is false here
        // and this becomes a cheap setActive(true) no-op.
        let otherPlaying = assertSessionOwnership(context: "startStream")

        if otherPlaying {
            // Force now-playing info re-assertion after session takeover so
            // the system picks up our metadata even if values haven't changed.
            lastNowPlayingTitle = nil
            lastNowPlayingArtist = nil
            lastNowPlayingState = nil
            lastNowPlayingRate = nil
            updateNowPlayingInfo()
        }

        // Request background execution time so the 20s buffering timeout
        // can fire even when iOS would otherwise suspend the process
        // (e.g., CarPlay with phone locked and VLC not yet producing audio).
        endBufferingBackgroundTask()
        bufferingBackgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "StreamBuffering") { [weak self] in
            self?.endBufferingBackgroundTask()
        }

        // Always create a fresh VLC player right before use.  During rapid
        // next/prev switching the player pre-created in play() may carry
        // stale libvlc state — it was allocated while the previous player's
        // async teardown was still in progress.  Deferring creation to here
        // (after the debounce) maximises the gap between old socket close
        // and new connection open, avoiding Xtream Codes connection-limit
        // rejections that leave VLC stuck in buffering with 0 bytes.
        //
        // Caching options are set at the instance level because VLCKit's
        // per-media addOptions uses libvlc_media_add_option which silently
        // rejects network-caching and live-caching as "unsafe" options.
        let effectiveBuffer = isReducedBufferRetry ? reducedBufferDuration : bufferDuration
        let cacheMs = Int(effectiveBuffer * 1000)
        log.log("VLC instance options: network-caching=\(cacheMs)ms, live-caching=\(cacheMs)ms, http-reconnect", category: .player)
        retirePlayer(options: [
            "--network-caching=\(cacheMs)",
            "--live-caching=\(cacheMs)",
            // Auto-reconnect on HTTP drops.  Dropped --http-continuous and
            // --audio-time-stretch in 1.1.x after they caused audible pitch
            // artifacts ("skipping") and forward-skips ("jump aheads") on
            // cellular drives.  Tried --ipv4-timeout / --ipv6-timeout in
            // build 144 and they crashed the libvlc instance init
            // (libvlc_media_player_new with NULL p_libvlc) — those options
            // are not recognized by this MobileVLCKit's bundled libvlc,
            // and passing them poisons VLCLibrary so the next player creation
            // segfaults.  Steady-state socket reads can NOT be bounded via
            // libvlc options anyway; the data-flow stale watchdog in
            // syncState() is the only mechanism for that.
            "--http-reconnect",
        ])

        let media = VLCMedia(url: channel.streamURL)
        media.addOptions([
            "http-user-agent": "AdagioStream/1.0",
        ])

        media.delegate = self
        mediaPlayer.media = media
        mediaPlayer.audio?.volume = 100

        // Lazy-start the AVAudioEngine on the first real playback
        // (idempotent — subsequent streams find it already running).
        AudioOutput.shared.start()

        // Route VLC's decoded PCM through our amem ring buffer →
        // AVAudioEngine pipeline instead of letting VLC's audiounit_ios
        // module own the audio output.  Phase 1 proved this prevents
        // the setActive(false, .notifyOthersOnDeactivation) that
        // resurrects Apple Music on channel change; phase 2 connects
        // the samples to AVAudioSourceNode so audio is actually heard.
        let preAttachPlay = VLCAudioCallbackBridge.playCallbackCount
        let attached = VLCAudioCallbackBridge.attachAudioCallbacks(
            to: mediaPlayer,
            sampleRate: AudioOutput.sampleRate,
            channels: AudioOutput.channelCount
        )
        log.log("amem bridge: attached=\(attached), rate=\(AudioOutput.sampleRate), channels=\(AudioOutput.channelCount), priorPlayCount=\(preAttachPlay)", category: .audioSession)

        mediaPlayer.play()
        isActiveSession = true
        log.log("play() started: playerState=\(vlcStateName(mediaPlayer.state)), willPlay=\(mediaPlayer.willPlay)", category: .player)

        // Poll state as a reliable fallback since VLC delegate
        // fires on a background thread that can miss MainActor updates
        currentPollInterval = fastPollInterval
        stateTimer = Timer.scheduledTimer(withTimeInterval: fastPollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.syncState()
            }
        }
    }

    /// Probes the stream server with a HEAD request before retrying VLC.
    /// Keeps probing every 2s until the server responds or the total timeout
    /// (probeTimeout) elapses.  Only starts VLC once the server is reachable,
    /// avoiding wasted player tear-down/create cycles on a dead network.
    private func probeAndRetryStream(for channel: Channel) {
        guard currentChannel?.id == channel.id else { return }

        let elapsed = Date().timeIntervalSince(probeStartTime ?? Date())
        if elapsed > probeTimeout {
            log.log("Connection timeout (\(Int(probeTimeout))s) — unable to reach stream server, channel=\"\(channel.name)\"", category: .player)
            probeStartTime = nil
            vlcZeroByteRetryCount = 0
            lastProbeHTTPStatus = nil
            isBuffering = false
            error = "Unable to connect — check your network connection."
            return
        }

        // Cap VLC-level retries: if the server is reachable but VLC
        // repeatedly gets 0 bytes, the stream itself is broken.
        if vlcZeroByteRetryCount >= maxVLCZeroByteRetries {
            let statusNote = lastProbeHTTPStatus.map { " (last HTTP \($0))" } ?? ""
            log.log("VLC failed \(vlcZeroByteRetryCount) times with 0 bytes despite server being reachable\(statusNote) — giving up, channel=\"\(channel.name)\"", category: .player)
            let userError = streamErrorMessage(httpStatus: lastProbeHTTPStatus)
            probeStartTime = nil
            vlcZeroByteRetryCount = 0
            lastProbeHTTPStatus = nil
            isBuffering = false
            error = userError
            return
        }

        channelChangeRetryCount += 1
        log.log("Probing stream server (attempt \(channelChangeRetryCount), \(String(format: "%.0f", elapsed))s elapsed), channel=\"\(channel.name)\"", category: .player)

        var request = URLRequest(url: channel.streamURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        request.setValue("AdagioStream/1.0", forHTTPHeaderField: "User-Agent")

        streamProbeTask = URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            Task { @MainActor in
                guard let self, self.currentChannel?.id == channel.id else { return }
                if let error {
                    // Server unreachable — wait and probe again
                    self.log.log("Stream probe failed: \(error.localizedDescription)", category: .player)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        self.probeAndRetryStream(for: channel)
                    }
                } else {
                    let httpStatus = (response as? HTTPURLResponse)?.statusCode
                    self.lastProbeHTTPStatus = httpStatus
                    let statusTag = httpStatus.map { " (HTTP \($0))" } ?? ""

                    // Auth failure — don't waste retries, fail fast
                    if let code = httpStatus, code == 401 || code == 403 {
                        self.log.log("Stream probe got HTTP \(code) — authentication rejected, channel=\"\(channel.name)\"", category: .player)
                        self.probeStartTime = nil
                        self.vlcZeroByteRetryCount = 0
                        self.lastProbeHTTPStatus = nil
                        self.isBuffering = false
                        self.error = "Authentication failed — check your provider credentials."
                        return
                    }

                    // Server responded — wait with exponential backoff before
                    // retrying VLC, so we don't spin in a tight loop when the
                    // server accepts connections but the stream has no data.
                    self.vlcZeroByteRetryCount += 1
                    let backoff = min(Double(1 << (self.vlcZeroByteRetryCount - 1)), 8.0) // 1s, 2s, 4s, 8s, 8s
                    let totalElapsed = Date().timeIntervalSince(self.probeStartTime ?? Date())
                    self.log.log("Stream server reachable\(statusTag) after \(String(format: "%.0f", totalElapsed))s, retrying VLC in \(String(format: "%.0f", backoff))s (attempt \(self.vlcZeroByteRetryCount)/\(self.maxVLCZeroByteRetries)), channel=\"\(channel.name)\"", category: .player)
                    DispatchQueue.main.asyncAfter(deadline: .now() + backoff) { [weak self] in
                        guard let self, self.currentChannel?.id == channel.id else { return }
                        self.probeStartTime = nil
                        self.lastLoggedVLCState = nil
                        self.startStream(for: channel)
                    }
                }
            }
        }
        streamProbeTask?.resume()
    }

    /// Returns a user-facing error message based on the last HTTP status from probing.
    private func streamErrorMessage(httpStatus: Int?) -> String {
        guard let code = httpStatus else {
            return "Stream unavailable — try again or switch channels."
        }
        switch code {
        case 200:
            return "Server responded but sent no stream data — the source may be down. Try again later."
        case 401, 403:
            return "Authentication failed — check your provider credentials."
        case 404:
            return "Stream not found — the channel may have been removed by the provider."
        case 500...599:
            return "Server error (HTTP \(code)) — the provider may be having issues. Try again later."
        default:
            return "Stream unavailable (HTTP \(code)) — try again or switch channels."
        }
    }

    /// Called when the app enters/leaves the background.
    public func setBackgroundMode(_ background: Bool) {
        isInBackground = background
        if background {
            adjustPollRate(to: backgroundPollInterval)
        } else {
            if isPlaying && !isBuffering && error == nil {
                adjustPollRate(to: slowPollInterval)
            } else {
                adjustPollRate(to: fastPollInterval)
            }
            recoverStaleInterruption()
        }
    }

    /// Pre-warm iOS's "now playing app" assertion at CarPlay connect time.
    /// After a CarPlay-only cold launch the audio session was activated by
    /// init() but iOS may not yet route MPRemoteCommandCenter events to us
    /// until something convinces it we're a now-playing candidate.  Writing
    /// a placeholder MPNowPlayingInfoCenter payload (rate=0, no title) is
    /// the documented signal that we intend to take that role; it's
    /// overwritten by updateNowPlayingInfo() as soon as a channel plays.
    /// Also logs the audio session and now-playing state so bd 651.2 has
    /// visible evidence of what iOS saw at connect time.
    public func prewarmRemoteCommands() {
        let session = AVAudioSession.sharedInstance()
        let category = session.category.rawValue
        let mode = session.mode.rawValue
        let outputs = session.currentRoute.outputs.map { "\($0.portName) (\($0.portType.rawValue))" }.joined(separator: ", ")
        let center = MPNowPlayingInfoCenter.default()
        let existingInfo = center.nowPlayingInfo
        let stateName: String
        switch center.playbackState {
        case .playing: stateName = "playing"
        case .paused: stateName = "paused"
        case .stopped: stateName = "stopped"
        case .interrupted: stateName = "interrupted"
        case .unknown: stateName = "unknown"
        @unknown default: stateName = "raw(\(center.playbackState.rawValue))"
        }
        log.log("prewarmRemoteCommands: session=\(category)/\(mode), outputs=[\(outputs)], existingInfo=\(existingInfo == nil ? "nil" : "present"), state=\(stateName)", category: .player)

        // Take ownership only if no one else has set NowPlayingInfo yet —
        // otherwise we'd stomp the active-stream payload on a CarPlay
        // reconnect that finds the app already playing.
        if existingInfo == nil {
            center.nowPlayingInfo = [
                MPNowPlayingInfoPropertyPlaybackRate: 0.0,
                MPNowPlayingInfoPropertyIsLiveStream: true,
            ]
            center.playbackState = .stopped
            log.log("prewarmRemoteCommands: wrote placeholder NowPlayingInfo to assert now-playing role", category: .player)
        }

        // Ensure the audio session is active.  If it was already activated
        // by init() this is a no-op; if a prior interruption left it
        // inactive without a delivered .ended event, this restores it so
        // MPRemoteCommandCenter targets become reachable.
        do {
            try session.setActive(true)
            log.log("prewarmRemoteCommands: session.setActive(true) OK", category: .audioSession)
        } catch {
            log.log("prewarmRemoteCommands: session.setActive(true) FAILED: \(error.localizedDescription)", category: .audioSession)
        }
    }

    /// Recover from an interruption whose ENDED event was never delivered.
    /// Called when the app returns to foreground or CarPlay reconnects.
    /// If `interruptedChannel` has been set for longer than 30 s with no
    /// active playback, the interruption handler clearly missed the resume
    /// event — force-clear and restart.
    public func recoverStaleInterruption() {
        guard let channel = interruptedChannel,
              let elapsed = interruptionTime.map({ Date().timeIntervalSince($0) }),
              elapsed > 30,
              !isPlaying, !isBuffering else { return }

        log.log("Stale interruption detected (\(Int(elapsed))s) for \"\(channel.name)\" — force-recovering", category: .interruption)

        // Clean up orphaned state
        isRidingOutInterruption = false
        interruptionFallbackWorkItem?.cancel()
        interruptionFallbackWorkItem = nil
        interruptedChannel = nil
        interruptionTime = nil
        timeShiftBuffer.cancelAndCleanup()

        play(channel: channel)
    }

    /// Reschedule the state timer at a new interval if it differs from the current one.
    private func adjustPollRate(to interval: TimeInterval) {
        guard abs(currentPollInterval - interval) > 0.1 else { return }
        currentPollInterval = interval
        stateTimer?.invalidate()
        stateTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
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
        stateTimer = Timer.scheduledTimer(withTimeInterval: fastPollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.syncState()
            }
        }
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

    public func pause() {
        log.log("pause() channel=\"\(currentChannel?.name ?? "nil")\"", category: .player)
        interruptedChannel = nil
        isRidingOutInterruption = false
        interruptionFallbackWorkItem?.cancel()
        interruptionFallbackWorkItem = nil
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
        timed("pause(): mediaPlayer.stop()") { mediaPlayer.stop() }
        // Drop anything still in the ring buffer so resuming doesn't
        // splash out the tail of pre-pause audio.
        VLCAudioCallbackBridge.flushBuffer()
        isPlaying = false
        isBuffering = false
        sxmService.stopPolling()
        updateNowPlayingInfo()

        // NOTE: deliberately do NOT deactivate the audio session here.
        // The AVAudioEngine in AudioOutput is running on this session;
        // setActive(false) tears the engine down and the next play
        // would produce no audio because engine.isRunning quietly
        // flips to false without raising an error.  Holding the
        // session active across pause is cheap (no audio is actually
        // flowing — the engine renders silence from the empty ring
        // buffer) and lets resume() pick up cleanly.
    }

    public func resume() {
        let channelName = (currentChannel ?? lastPlayedChannel)?.name ?? "nil"
        log.log("resume() channel=\"\(channelName)\"", category: .player)
        guard let channel = currentChannel ?? lastPlayedChannel else {
            log.log("resume() aborted: no channel available", category: .player)
            return
        }
        play(channel: channel)
    }

    public func togglePlayPause() {
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

    /// Full session teardown — clears interruption state so the stream
    /// won't auto-resume on next CarPlay connect.  Use this when the user
    /// explicitly ends a session (e.g. CarPlay disconnect).
    public func stopAndClearInterruption() {
        interruptedChannel = nil
        interruptionTime = nil
        stop()
    }

    public func stop() {
        log.log("stop() channel=\"\(currentChannel?.name ?? "nil")\"", category: .player)
        // Note: do NOT clear interruptedChannel here — stop() is called
        // by the interruption handler after saving the channel to resume.
        // Only pause() and play() should clear it (explicit user actions).
        isRidingOutInterruption = false
        interruptionFallbackWorkItem?.cancel()
        interruptionFallbackWorkItem = nil
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
        endBufferingBackgroundTask()
        streamProbeTask?.cancel()
        streamProbeTask = nil
        probeStartTime = nil
        vlcZeroByteRetryCount = 0
        listeningStartDate = nil
        accumulatedListeningTime = 0
        timed("stop(): mediaPlayer.stop()") { mediaPlayer.stop() }
        timed("stop(): mediaPlayer.media=nil") { mediaPlayer.media = nil }
        lastPlayedChannel = currentChannel
        currentChannel = nil
        isPlaying = false
        isBuffering = false
        currentArtwork = nil
        sxmArtwork = nil
        if interruptedChannel != nil {
            // Interruption — keep polling so track history stays current
            interruptionTime = Date()
            sxmService.suspendForTimeShift()
        } else {
            interruptionTime = nil
            bufferPlaybackStartedAt = nil
            sxmService.stopPolling()
        }
        streamTitle = nil
        streamArtist = nil
        clearNowPlayingInfo()
    }

    public func playNext() {
        let list = channels.isEmpty ? ProviderManager.shared.channels : channels
        guard !list.isEmpty,
              let current = currentChannel ?? lastPlayedChannel,
              let index = list.firstIndex(where: { $0.id == current.id }) else { return }
        channels = list
        let nextIndex = (index + 1) % list.count
        play(channel: list[nextIndex])
    }

    public func playPrevious() {
        let list = channels.isEmpty ? ProviderManager.shared.channels : channels
        guard !list.isEmpty,
              let current = currentChannel ?? lastPlayedChannel,
              let index = list.firstIndex(where: { $0.id == current.id }) else { return }
        channels = list
        let prevIndex = (index - 1 + list.count) % list.count
        play(channel: list[prevIndex])
    }

    public func updateBufferDuration(_ duration: TimeInterval) {
        let previous = bufferDuration
        bufferDuration = duration
        if abs(previous - duration) > 0.01 {
            log.log("bufferDuration set to \(Int(duration))s (was \(Int(previous))s)", category: .player)
        }
    }

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

            // ID3 tags take precedence if available
            if let metaTitle, !metaTitle.isEmpty, metaTitle != self.currentChannel?.name {
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

    // MARK: - State Sync

    private func syncState() {
        guard isActiveSession else { return }

        // While riding out a short interruption, VLC's state may fluctuate
        // as iOS silences its audio output.  Don't react to state changes
        // (no probing, no retries, no error handling) until the interruption
        // ends and we can assess VLC's actual health.
        if isRidingOutInterruption { return }

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

        // During the initial buffer fill, VLC reports isPlaying=true after
        // ~1.3s when it identifies the stream format, but zero audio frames
        // have been decoded — the 8s network-caching is still filling.
        // Don't declare "playing" until audio frames are actually decoded.
        let audioDecoded = mediaPlayer.media?.statistics.decodedAudio ?? 0
        let awaitingInitialBuffer = streamStartTime != nil && audioDecoded == 0
            && !isPlayingBufferedFile

        // Track data flow for the silent-dropout watchdog.
        if hasDataFlow || vlcIsPlaying {
            lastDataFlowTime = Date()
            lastActiveDecodedAudio = audioDecoded
        }

        // Log when the initial buffer fill completes (awaitingInitialBuffer flips true→false).
        if wasAwaitingInitialBuffer && !awaitingInitialBuffer, let start = streamStartTime {
            let elapsed = Date().timeIntervalSince(start)
            let bytesRead = mediaPlayer.media?.statistics.readBytes ?? 0
            log.log("Initial buffer filled: elapsed=\(String(format: "%.1f", elapsed))s, decodedAudio=\(audioDecoded), readBytes=\(bytesRead), vlcState=\(vlcStateName(vlcState)), isPlaying=\(vlcIsPlaying)", category: .player)
            wasAwaitingInitialBuffer = false
        }

        // Detect mid-stream audio buffer loss (causes audible blips/stutters).
        if let media = mediaPlayer.media, !awaitingInitialBuffer {
            let stats = media.statistics
            let lostDelta = stats.lostAudioBuffers - lastLoggedLostAudioBuffers
            let discDelta = stats.demuxDiscontinuity - lastLoggedDiscontinuity
            if lostDelta > 0 || discDelta > 0 {
                log.log("Buffer underrun: lostAudio=+\(lostDelta) (total=\(stats.lostAudioBuffers)), discontinuity=+\(discDelta) (total=\(stats.demuxDiscontinuity)), played=\(stats.playedAudioBuffers), in=\(String(format: "%.1f", stats.inputBitrate * 1000))kbps, demux=\(String(format: "%.1f", stats.demuxBitrate * 1000))kbps, read=\(stats.readBytes)B", category: .player)
                lastLoggedLostAudioBuffers = stats.lostAudioBuffers
                lastLoggedDiscontinuity = stats.demuxDiscontinuity
            }
        }

        if (vlcIsPlaying || vlcState == .playing) && !awaitingInitialBuffer {
            isPlaying = true
            isBuffering = false
            error = nil
            endBufferingBackgroundTask()
        } else if hasDataFlow && !awaitingInitialBuffer && (vlcState == .buffering || vlcState == .opening) {
            // VLC says buffering but data is flowing — audio is actually playing
            isPlaying = true
            isBuffering = false
            error = nil
            endBufferingBackgroundTask()
        } else if awaitingInitialBuffer && (vlcIsPlaying || hasDataFlow) {
            // VLC engine is running but no audio decoded yet — still filling
            // the network-caching buffer.  Keep showing buffering state.
            wasAwaitingInitialBuffer = true
            isBuffering = true
            isPlaying = false
            let bytesRead = mediaPlayer.media?.statistics.readBytes ?? 0
            if bytesRead > 0 { hasReceivedData = true; vlcZeroByteRetryCount = 0 }
        } else {
            switch vlcState {
            case .buffering, .opening:
                isBuffering = true
                // Track when data first arrives
                let bytesRead = mediaPlayer.media?.statistics.readBytes ?? 0
                if bytesRead > 0 { hasReceivedData = true; vlcZeroByteRetryCount = 0 }

                // Silent dropout watchdog: stream was previously playing
                // (has received data, decoded audio frames) but data flow
                // has now stopped without any VLC error or state change.
                // Auto-reconnect after dataFlowStaleTimeout seconds.
                if hasReceivedData, lastActiveDecodedAudio > 0,
                   let lastFlow = lastDataFlowTime,
                   Date().timeIntervalSince(lastFlow) > dataFlowStaleTimeout,
                   let channel = currentChannel {
                    log.log("Silent dropout detected — no data flow for \(Int(dataFlowStaleTimeout))s after \(lastActiveDecodedAudio) decoded frames, reconnecting channel=\"\(channel.name)\"", category: .player)
                    lastLoggedVLCState = nil
                    isReducedBufferRetry = false
                    startStream(for: channel)
                }
                // Timeout: if buffering too long with no meaningful data, retry with smaller buffer
                else if let start = streamStartTime, !hasReceivedData,
                   Date().timeIntervalSince(start) > bufferingTimeoutInterval,
                   !isReducedBufferRetry,
                   let channel = currentChannel {
                    log.log("Buffering timeout (\(Int(bufferingTimeoutInterval))s with no data) — retrying with reduced buffer (\(Int(reducedBufferDuration))s), channel=\"\(channel.name)\"", category: .player)
                    isReducedBufferRetry = true
                    lastLoggedVLCState = nil
                    startStream(for: channel)
                } else if let start = streamStartTime, !hasReceivedData,
                          isReducedBufferRetry,
                          Date().timeIntervalSince(start) > bufferingTimeoutInterval,
                          currentChannel != nil {
                    log.log("Reduced-buffer retry also timed out — giving up, channel=\"\(currentChannel?.name ?? "nil")\"", category: .player)
                    isActiveSession = false
                    stateTimer?.invalidate()
                    stateTimer = nil
                    endBufferingBackgroundTask()
                    timed("giveup: mediaPlayer.stop()") { mediaPlayer.stop() }
                    timed("giveup: mediaPlayer.media=nil") { mediaPlayer.media = nil }
                    isPlaying = false
                    isBuffering = false
                    error = "Unable to connect — no data received after multiple attempts. Check your network or provider status."
                }
            case .paused:
                isPlaying = false
                isBuffering = false
            case .stopped:
                if currentChannel != nil {
                    isPlaying = false
                    if isActiveSession {
                        let bytesRead = mediaPlayer.media?.statistics.readBytes ?? 0
                        if bytesRead == 0 {
                            // Connection failed before receiving any data — could be
                            // network unreachable, DNS failure, or server not ready.
                            // Probe the server with a lightweight HTTP request before
                            // retrying VLC, so we don't burn attempts on a dead network.
                            log.log("VLC stopped with 0 bytes — probing server reachability, channel=\"\(currentChannel?.name ?? "nil")\"", category: .vlcState)
                            isActiveSession = false
                            stateTimer?.invalidate()
                            stateTimer = nil
                            isBuffering = true
                            if probeStartTime == nil {
                                probeStartTime = Date()
                            }
                            if let channel = currentChannel {
                                probeAndRetryStream(for: channel)
                            }
                        } else {
                            isBuffering = false
                            log.log("VLC stopped unexpectedly after \(bytesRead) bytes, channel=\"\(currentChannel?.name ?? "nil")\"", category: .vlcState)
                            isActiveSession = false
                            stateTimer?.invalidate()
                            stateTimer = nil
                        }
                    } else {
                        isBuffering = false
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
                        // Reset isActiveSession so play() doesn't skip with
                        // "already active" — VLC just finished the buffer file
                        // and has no data; it needs a fresh live connection.
                        isActiveSession = false
                        stateTimer?.invalidate()
                        stateTimer = nil
                        timeShiftBuffer.cancelAndCleanup()
                        play(channel: channel)
                    }
                }
            default:
                break
            }
        }

        // During buffer playback, estimate what time the audio is from
        // and show the matching SXM track from history
        if isPlayingBufferedFile, let intTime = interruptionTime, let pbStart = bufferPlaybackStartedAt {
            let elapsed = Date().timeIntervalSince(pbStart)
            let estimatedAudioTime = intTime.addingTimeInterval(elapsed)
            sxmService.showTrack(at: estimatedAudioTime)
        }

        updateStreamStats()
        updateNowPlayingInfo()

        // Adaptive timer: background → very slow, stable play → slow, transitions → fast
        if isInBackground {
            adjustPollRate(to: backgroundPollInterval)
        } else if isPlaying && !isBuffering && error == nil {
            adjustPollRate(to: slowPollInterval)
        } else {
            adjustPollRate(to: fastPollInterval)
        }
    }

    // MARK: - Stream Stats

    private func updateStreamStats() {
        guard currentChannel != nil else {
            if !statusText.isEmpty { statusText = "" }
            if streamBitrateKbps != 0 { streamBitrateKbps = 0 }
            return
        }

        if let media = mediaPlayer.media {
            let stats = media.statistics
            let currentKbps = Double(stats.demuxBitrate) * 1000

            if currentKbps > 1 {
                // Smooth with EMA so initial buffer-fill spikes settle.
                // Round to integer to avoid publishing micro-changes.
                let newKbps: Double
                if streamBitrateKbps < 1 {
                    newKbps = currentKbps
                } else {
                    newKbps = streamBitrateKbps * 0.8 + currentKbps * 0.2
                }
                let rounded = (newKbps * 10).rounded() / 10
                if abs(rounded - streamBitrateKbps) >= 0.5 {
                    streamBitrateKbps = rounded
                }
            }
        }

        let newText: String
        if isPlayingBufferedFile {
            let duration = String(format: "%.0f", timeShiftBuffer.capturedDuration)
            newText = "Catching up \u{00B7} \(duration)s behind"
        } else if isBuffering {
            newText = "Buffering... (cache: \(Int(bufferDuration))s)"
        } else if isPlaying {
            if streamBitrateKbps > 1 {
                let formatted = streamBitrateKbps >= 1000
                    ? String(format: "%.1f Mbps", streamBitrateKbps / 1000)
                    : "\(Int(streamBitrateKbps)) kbps"
                newText = "Live \u{00B7} \(formatted)"
            } else {
                newText = "Live"
            }
        } else {
            newText = ""
        }
        if statusText != newText { statusText = newText }
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
        updateNowPlayingInfo()
    }

    private func updateNowPlayingInfo() {
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

        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = state

        let stateName: String
        switch state {
        case .playing: stateName = "playing"
        case .paused: stateName = "paused"
        case .stopped: stateName = "stopped"
        case .interrupted: stateName = "interrupted"
        case .unknown: stateName = "unknown"
        @unknown default: stateName = "raw(\(state.rawValue))"
        }
        log.log("NowPlaying set: source=\(source), title=\"\(title)\", artist=\"\(artist)\", album=\"\(channel.name)\", isLive=\(isLive), state=\(stateName), rate=\(rate), hasArtwork=\(artwork != nil)", category: .player)
    }

    private func fetchSXMArtwork(url: URL, trackID: String) {
        Task {
            guard let image = await ImageCacheService.shared.ephemeralImage(for: url) else { return }
            guard self.sxmService.currentTrack?.id == trackID else { return }
            self.sxmArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.updateNowPlayingInfo()
        }
    }

    private func fetchArtwork(for channel: Channel) {
        guard let logoURL = channel.logoURL else { return }
        Task {
            guard let image = await ImageCacheService.shared.image(for: logoURL) else { return }
            guard self.currentChannel?.id == channel.id else { return }
            self.currentArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.updateNowPlayingInfo()
        }
    }

    private func clearNowPlayingInfo() {
        log.log("NowPlaying cleared", category: .player)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        lastNowPlayingTitle = nil
        lastNowPlayingArtist = nil
        lastNowPlayingIsLive = nil
        lastNowPlayingRate = nil
        lastNowPlayingState = nil
        lastNowPlayingArtwork = nil
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

        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            DebugLogger.shared.log("Remote command: NEXT_TRACK", category: .remoteCommand)
            Task { @MainActor in self?.playNext() }
            return .success
        }

        commandCenter.previousTrackCommand.isEnabled = true
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

#endif // os(iOS)
