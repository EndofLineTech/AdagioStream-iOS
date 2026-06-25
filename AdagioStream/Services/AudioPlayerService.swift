import AVFoundation
import Combine
import MediaPlayer
import Network
import SwiftUI
@preconcurrency import VLCKitSPM
#if os(iOS)
import UIKit
#endif

@MainActor
public final class AudioPlayerService: NSObject, ObservableObject, VLCMediaPlayerDelegate, VLCMediaDelegate {
    public static let shared = AudioPlayerService()
    private let log = DebugLogger.shared

    @Published public var currentChannel: Channel?

    // MARK: - PlaybackSource seam (d6q.7, Phase 1)
    //
    // Additive — currentChannel is kept exactly as-is; playbackSource mirrors
    // it.  Phase 1 always sets .radio; .library is reserved for d6q.2.
    @Published public var playbackSource: PlaybackSource?

    /// The item currently displayed in the Now Playing / mini-player UI.
    /// Derives from `playbackSource`; returns nil when nothing is playing.
    public var nowPlaying: (any NowPlayingItem)? {
        playbackSource?.currentItem
    }

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

    // MARK: - Wedge watchdog (bd a14)
    // Diagnostic-only. Samples the render pipeline every few seconds while we
    // believe audio is playing. If VLC reports playing but the AVAudioEngine
    // is dead or its render thread is frozen, the stream is silently wedged —
    // the unrecoverable CarPlay/Siri state that leaves no crash dump. We log a
    // full snapshot so the next field capture is unambiguous; no behavior change.
    private var wedgeWatchdogTimer: Timer?
    private var lastRenderCallSample = 0
    private var lastPlayCallbackSample = 0
    private var wedgeSuspectSince: Date?
    private let fastPollInterval: TimeInterval = 0.5
    private let slowPollInterval: TimeInterval = 3.0
    private let backgroundPollInterval: TimeInterval = 10.0
    private var currentPollInterval: TimeInterval = 0.5
    private var isInBackground = false
    private var currentArtwork: MPMediaItemArtwork?
    private var sxmArtwork: MPMediaItemArtwork?
    /// The track being played in `.library` mode; nil when in radio mode.
    private var currentTrack: Track?

    // MARK: - Scrobble state (65x.1)

    /// Scrobble state + fire helpers.  Extracted to Scrobbler.swift; AudioPlayerService
    /// owns the instance and delegates reset/fire calls to it.
    private let scrobbler = Scrobbler()

    /// Human-readable artist display name threaded in from the album context
    /// by `play(track:displayArtistName:via:)`.  Used to build the lock-screen
    /// now-playing info (`updateNowPlayingInfoForTrack`).
    /// Cleared each time a new track starts so stale names never bleed through.
    private var currentTrackArtistName: String?

    /// Published mirror of `currentTrackArtistName` for the in-app mini/full
    /// player subtitle (bug hzl).  `Track.displaySubtitle` is nil (it only knows
    /// `artistId`), so the player reads this for the library subtitle instead of
    /// the now-playing item.  Nil when nothing is playing, in radio mode, or when
    /// no display artist was threaded (e.g. playlist/search playback).
    @Published public private(set) var nowPlayingSubtitle: String?

    /// Resolved cover-art URL for the currently-playing library track, for the
    /// in-app mini/full player artwork (bug rendering).  `Track.artworkURL` is nil
    /// (the model can't build an authed getCoverArt URL without an API context),
    /// so the player reads this instead.  Built from `track.coverArt` via the
    /// queue API at track start; nil in radio mode or when the track has no art.
    @Published public private(set) var nowPlayingArtworkURL: URL?

    /// Artwork loaded for the currently-playing track (cover art from Navidrome).
    private var currentTrackArtwork: MPMediaItemArtwork?

    // MARK: - Queue state (d6q.1)

    /// The index of the currently-playing track within the `.library` queue.
    /// Nil when in radio mode or when nothing is playing.
    @Published public private(set) var currentQueueIndex: Int?

    // MARK: - Elapsed + Duration (d6q.6)

    /// Current playback position in seconds for the active library track.
    /// 0.0 when in radio mode or when no track is playing.
    /// Updated every timer tick (0.5–3s) from VLC; the UI seek bar reads this
    /// and uses its own local @State while scrubbing so it doesn't fight the timer.
    @Published public private(set) var trackElapsed: Double = 0.0

    /// Duration in seconds of the active library track.
    /// Nil when unknown (radio, or library track whose duration is not yet parsed).
    /// Sourced first from VLC's parsed media length; falls back to `Track.duration`.
    @Published public private(set) var trackDuration: Double? = nil

    // MARK: - Repeat + Shuffle (d6q.4)

    /// Repeat mode for the library queue (`.off` / `.all` / `.one`).
    ///
    /// - `.off`: Play through the queue once and stop at the end.
    /// - `.all`: After the last track, wrap to index 0 and continue.
    /// - `.one`: On natural track-end, restart the same track.  Manual
    ///           next/previous still moves to the adjacent track — `.one` only
    ///           governs auto-advance, not user-initiated navigation.
    ///
    /// Radio is unaffected; this value is ignored when `playbackSource == .radio`.
    @Published public var repeatMode: RepeatMode = .off

    /// Whether the library queue plays in shuffled order.
    ///
    /// **Order model:** the canonical `[Track]` queue inside `PlaybackSource`
    /// is never mutated.  When shuffle is enabled, `shuffleOrder` holds a
    /// permutation of indices into that queue.  `shufflePosition` is the
    /// cursor into `shuffleOrder` (so `shuffleOrder[shufflePosition]` is the
    /// index of the currently-playing track in the canonical queue).
    ///
    /// **Toggle-on behaviour:** the current track keeps playing; the remaining
    /// positions in `shuffleOrder` after the current one are shuffled randomly.
    ///
    /// **Toggle-off behaviour:** `shuffleOrder` is cleared.  Navigation resumes
    /// using the track's natural index in the canonical queue (the value already
    /// stored in `currentQueueIndex`).
    ///
    /// **Wrap-on-repeat-all:** when `repeatMode == .all` and the shuffle cursor
    /// reaches the end, the order is reshuffled from scratch (the current track
    /// is allowed to appear at any position in the new order — it may repeat
    /// back-to-back).
    ///
    /// Radio is unaffected.
    @Published public var shuffleEnabled: Bool = false

    /// The shuffled index sequence.  Each element is an index into the
    /// canonical queue.  Empty when shuffle is off.
    ///
    /// Invariant while shuffle is on: `shuffleOrder` is a permutation of
    /// `0..<queue.count`.  The element at `shufflePosition` equals
    /// `currentQueueIndex`.
    private var shuffleOrder: [Int] = []

    /// Cursor into `shuffleOrder` pointing at the currently-playing track.
    /// Undefined when `shuffleEnabled == false`.
    private var shufflePosition: Int = 0

    /// The display artist name that applies to every track in the current
    /// library queue (e.g. the album artist).  Stored alongside the queue so
    /// it carries forward as next/previous advance the index.
    /// Per-track artist is preferred if the track itself exposes one; this
    /// value is the queue-level fallback when the track's own subtitle is
    /// just an `artistId`.
    private var queueDisplayArtistName: String?

    /// The NavidromeAPI instance in use for the current library queue.
    /// Retained so `playNextInQueue()` and `playPreviousInQueue()` can build
    /// stream URLs without the UI having to re-supply `api` on every call.
    private var queueAPI: NavidromeAPI?

    /// The ordered list of `Track` objects in the current library queue.
    /// Derived from `playbackSource` so it is always in sync with the
    /// authoritative state.  Returns `[]` when in radio mode.
    public var currentLibraryQueue: [Track] {
        guard case .library(let queue, _) = playbackSource else { return [] }
        return queue
    }
    private var lastPlayedChannel: Channel?
    private var interruptedChannel: Channel?

    // MARK: - Interruption capture state (d6q.8)
    //
    // Full PlaybackSource snapshot taken at interruption .began.  The legacy
    // `interruptedChannel` field is kept intact because `stop()` checks it to
    // decide whether to preserve the AVAudioEngine (interruption path vs. user
    // stop).  The new fields carry what `interruptedChannel` cannot: the full
    // library queue + index + API needed to cold-restart a library track.
    //
    // Invariants:
    //   - Both are set together at .began and cleared together at .ended/.resume.
    //   - For `.radio`, `interruptedSource` mirrors `interruptedChannel`; the
    //     `.ended` path still routes through `reactivateAndPlay(channel:)` so
    //     existing radio behaviour is provably unchanged.
    //   - For `.library`, `interruptedSource` carries the full queue snapshot
    //     captured *before* any `stop()` tears it down.  `interruptedQueueAPI`
    //     carries the NavidromeAPI reference (also cleared by `stop()`).
    //   - `interruptedElapsedSeconds`: VLC elapsed at capture (seconds, ≥ 0).
    //     Nil if position was not yet known (track just started).  Used only
    //     for `.library`; ignored for radio.
    private var interruptedSource: PlaybackSource?
    private var interruptedQueueAPI: NavidromeAPI?
    private var interruptedElapsedSeconds: Double?

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
    #if os(iOS)
    private var bufferingBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    #endif
    private var lastNowPlayingTitle: String?
    private var lastNowPlayingArtist: String?
    private var lastNowPlayingIsLive: Bool?
    private var lastNowPlayingRate: Double?
    private var lastNowPlayingState: MPNowPlayingPlaybackState?
    private var lastNowPlayingArtwork: MPMediaItemArtwork?
    /// Last elapsed time (seconds) written to MPNowPlayingInfoCenter for change-detection.
    /// nil when in radio mode or nothing is playing.
    private var lastNowPlayingElapsed: Double?
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
    /// Diagnostic counters for began/ended pairing.  A Siri-initiated call can
    /// post multiple .began with a single .ended; the asymmetry is a clue that
    /// another interruption (e.g. an active call) is still outstanding when we
    /// resume.  Instrumentation only — see beads_mobilemusic-lfn.
    private var interruptionBeganCount = 0
    private var interruptionEndedCount = 0
    private var pathMonitor: NWPathMonitor?
    private let pathMonitorQueue = DispatchQueue(label: "com.adagiostream.pathmonitor")
    private var lastPathStatus: NWPath.Status?
    private var lastPrimaryInterface: NWInterface.InterfaceType?
    private var lastPathReconnectTime: Date = .distantPast
    /// Minimum interval between path-monitor-triggered reconnects.  A subway
    /// or tower handoff can fire several path events in quick succession;
    /// without a cooldown we'd tear down and rebuild the player repeatedly.
    private let pathReconnectCooldown: TimeInterval = 5
    /// Pending retry for an automatic reconnect that was deferred because
    /// other audio (a phone call, a nav prompt, another media app) owned the
    /// session at takeover time.  Polls until that audio releases.
    private var deferredReconnectWorkItem: DispatchWorkItem?
    /// How long an automatic reconnect keeps waiting for other audio to
    /// release before giving up (leaving the channel set for manual resume).
    private let deferredReconnectMaxAttempts = 90

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

        startWedgeWatchdog()
    }

    // MARK: - Wedge Watchdog

    private func startWedgeWatchdog() {
        wedgeWatchdogTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkAudioHealth() }
        }
        timer.tolerance = 1.0
        wedgeWatchdogTimer = timer
    }

    /// Diagnostic-only health probe. Detects the silent wedge: we believe audio
    /// is playing, but the render pipeline isn't draining (engine dead or render
    /// thread frozen). Logs a full snapshot after the condition persists across
    /// two ticks so transient buffering gaps don't trip it.
    private func checkAudioHealth() {
        let renderNow = VLCAudioCallbackBridge.renderCallCount
        let playNow = VLCAudioCallbackBridge.playCallbackCount

        // Only meaningful while we believe a stream is actively playing.
        guard isActiveSession, let channel = currentChannel,
              mediaPlayer.isPlaying || mediaPlayer.state == .buffering else {
            wedgeSuspectSince = nil
            lastRenderCallSample = renderNow
            lastPlayCallbackSample = playNow
            return
        }

        let engineRunning = AudioOutput.shared.isRunning
        let rendersAdvancing = renderNow != lastRenderCallSample
        lastRenderCallSample = renderNow
        let producing = playNow != lastPlayCallbackSample
        lastPlayCallbackSample = playNow

        // Healthy: engine up AND its render block is being called.
        if engineRunning && rendersAdvancing {
            wedgeSuspectSince = nil
            return
        }

        // Suspicious: VLC thinks it's playing but the pipeline is frozen.
        let since = wedgeSuspectSince ?? Date()
        wedgeSuspectSince = since
        let stuckFor = Date().timeIntervalSince(since)
        guard stuckFor >= 6 else { return }

        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
            .map { "\($0.portName) (\($0.portType.rawValue))" }.joined(separator: ", ")
        log.log("WEDGE SUSPECTED for \"\(channel.name)\" — stuck \(Int(stuckFor))s | engineRunning=\(engineRunning) startFailStreak=\(AudioOutput.shared.startFailureStreak) rendersAdvancing=\(rendersAdvancing) vlcProducing=\(producing) | vlcState=\(vlcStateName(mediaPlayer.state)) isPlaying=\(mediaPlayer.isPlaying) | bufferedFrames=\(VLCAudioCallbackBridge.bufferedFrames) renderUnderruns=\(VLCAudioCallbackBridge.renderUnderrunCount) droppedFrames=\(VLCAudioCallbackBridge.droppedFrameCount) | route=[\(outputs)]", category: .audioSession)
        // Re-arm so a persistent wedge keeps logging roughly every 6s rather
        // than once, giving the field log a duration signal.
        wedgeSuspectSince = Date()
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
        // d6q.8: dispatch on interruptedSource (not just interruptedChannel)
        // so library playback also resumes via this path.
        if type == .end {
            Task { @MainActor in
                guard let capturedSource = self.interruptedSource else { return }
                let sourceDesc: String = {
                    switch capturedSource {
                    case .radio(let ch): return "radio(\"\(ch.name)\")"
                    case .library(_, let idx): return "library(index=\(idx))"
                    }
                }()
                self.log.log("Secondary audio hint .end: resuming \(sourceDesc)", category: .interruption)
                self.interruptedChannel = nil
                self.interruptedSource = nil
                let savedAPI = self.interruptedQueueAPI
                let savedElapsed = self.interruptedElapsedSeconds
                self.interruptedQueueAPI = nil
                self.interruptedElapsedSeconds = nil

                switch capturedSource {
                case .radio(let channel):
                    let bufferFileURL = self.timeShiftBuffer.stopCapture()
                    self.log.log("Time-shift buffer: \(bufferFileURL != nil ? "available" : "none")", category: .interruption)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.reactivateAndPlay(channel: channel, bufferFileURL: bufferFileURL)
                    }
                case .library(let queue, let index):
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        guard let api = savedAPI, index < queue.count else {
                            self.log.log("Secondary hint library resume: missing API or index OOB — safe no-op", category: .interruption)
                            return
                        }
                        self.reactivateAndPlayLibraryTrack(queue[index], inQueue: queue, at: index, via: api, seekTo: savedElapsed)
                    }
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
                self.interruptionBeganCount += 1
                self.log.log("Interruption BEGAN: isActive=\(self.isActiveSession), channel=\"\(self.currentChannel?.name ?? "nil")\", vlcState=\(self.mediaPlayer.state.rawValue), beganCount=\(self.interruptionBeganCount), endedCount=\(self.interruptionEndedCount)", category: .interruption)
                self.logAudioSessionSnapshot("interruption.began")
                // 46u: suppress AVAudioEngine restart during ride-out so a
                // route/format change fired by Siri does not leak audio.
                AudioOutput.shared.noteInterruptionBegan()

                // Keep VLC alive during short interruptions — its internal
                // network-caching buffer (typically 8s) bridges the gap
                // without needing a cold restart.  Only fall back to
                // stop-and-capture if the interruption exceeds bufferDuration.
                //
                // d6q.8: capture the full PlaybackSource at .began so the
                // .ended handler can restore radio OR library correctly.
                // The legacy interruptedChannel guard in stop() requires the
                // channel to be set for radio; for library we set it to nil
                // (no radio buffer capture needed) but still set isRidingOut.
                if self.isActiveSession,
                   let snapshot = self.captureInterruptionSnapshot() {
                    // d6q.8: snapshot full source + position BEFORE any teardown.
                    self.interruptedSource = snapshot.source
                    self.interruptedQueueAPI = snapshot.queueAPI
                    self.interruptedElapsedSeconds = snapshot.elapsedSeconds

                    // Legacy channel field: set for radio so stop()'s engine-
                    // preservation guard fires; nil for library (no time-shift).
                    if case .radio(let channel) = snapshot.source {
                        self.interruptedChannel = channel
                    } else {
                        self.interruptedChannel = nil
                    }

                    self.isRidingOutInterruption = true

                    // Convenience alias for the fallback closure (radio only).
                    let radioChannel: Channel? = {
                        if case .radio(let ch) = snapshot.source { return ch }
                        return nil
                    }()
                    let currentBitrate = self.streamBitrateKbps

                    if let channel = radioChannel {
                        self.log.log("Riding out interruption for radio \"\(channel.name)\" (VLC cache \(Int(self.bufferDuration))s)", category: .interruption)
                    } else {
                        self.log.log("Riding out interruption for library source (VLC cache \(Int(self.bufferDuration))s)", category: .interruption)
                    }

                    // Safety net: if the interruption runs longer than VLC's
                    // cache, fall back to the old stop+capture path.
                    let interruptionStarted = Date()
                    let capturedSource = snapshot.source   // captured for fallback closure
                    let capturedAPI = snapshot.queueAPI
                    let capturedElapsed = snapshot.elapsedSeconds
                    let fallback = DispatchWorkItem { [weak self] in
                        guard let self, self.isRidingOutInterruption else { return }
                        // Verify we are still in the same interruption context.
                        let sourceStillMatches: Bool = {
                            switch (capturedSource, self.interruptedSource) {
                            case (.radio(let a), .radio(let b)): return a.id == b.id
                            case (.library(_, let ai), .library(_, let bi)): return ai == bi
                            default: return false
                            }
                        }()
                        guard sourceStillMatches else { return }

                        let elapsed = Date().timeIntervalSince(interruptionStarted)
                        self.log.log("Interruption exceeded VLC cache (\(Int(self.bufferDuration))s) — elapsed \(Int(elapsed))s, falling back to stop+capture", category: .interruption)
                        self.isRidingOutInterruption = false

                        if let channel = radioChannel {
                            // Radio: existing stop+capture path.
                            // Re-set interruptedChannel so stop()'s engine-guard fires.
                            self.interruptedChannel = channel
                            self.stop()
                            self.interruptedChannel = channel
                            self.interruptedSource = capturedSource
                            self.interruptedQueueAPI = nil  // not used for radio
                            self.interruptedElapsedSeconds = nil
                            if elapsed <= 30 {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    guard case .radio(let ch) = self.interruptedSource,
                                          ch.id == channel.id else { return }
                                    self.timeShiftBuffer.startCapture(for: channel, estimatedBitrateKbps: currentBitrate)
                                }
                            } else {
                                self.log.log("Skipping time-shift capture — interruption too stale (\(Int(elapsed))s)", category: .interruption)
                            }
                        } else {
                            // Library: stop the player; preserve the source snapshot
                            // (stop() clears playbackSource/queueAPI — we already
                            // captured what we need above).
                            self.interruptedChannel = nil   // no time-shift for library
                            self.stop()
                            // Restore the full snapshot so .ended can restart the track.
                            self.interruptedSource = capturedSource
                            self.interruptedQueueAPI = capturedAPI
                            self.interruptedElapsedSeconds = capturedElapsed
                            self.log.log("Library interruption exceeded VLC cache — source captured, waiting for .ended", category: .interruption)
                        }
                    }
                    self.interruptionFallbackWorkItem = fallback
                    DispatchQueue.main.asyncAfter(deadline: .now() + self.bufferDuration, execute: fallback)
                }

            case .ended:
                self.interruptionEndedCount += 1
                // 46u: clear interruption gate so the engine can restart.
                AudioOutput.shared.noteInterruptionEnded()
                let options = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let shouldResume = AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
                // beganCount > endedCount means a prior .began has not yet been
                // matched by its .ended — another interruption (e.g. an active
                // phone call) may still own audio even though THIS .ended fired.
                let unmatchedBegans = self.interruptionBeganCount - self.interruptionEndedCount
                // d6q.8: log both the legacy channel and the full source for diagnosis.
                let sourceDesc: String = {
                    switch self.interruptedSource {
                    case .radio(let ch): return "radio(\"\(ch.name)\")"
                    case .library(_, let idx): return "library(index=\(idx))"
                    case nil: return "nil"
                    }
                }()
                self.log.log("Interruption ENDED: interruptedSource=\(sourceDesc), interruptedChannel=\"\(self.interruptedChannel?.name ?? "nil")\", shouldResume=\(shouldResume), ridingOut=\(self.isRidingOutInterruption), beganCount=\(self.interruptionBeganCount), endedCount=\(self.interruptionEndedCount), unmatchedBegans=\(unmatchedBegans)", category: .interruption)
                self.logAudioSessionSnapshot("interruption.ended")

                // Cancel the fallback timer — interruption ended in time
                self.interruptionFallbackWorkItem?.cancel()
                self.interruptionFallbackWorkItem = nil

                // d6q.8: gate on interruptedSource (not just interruptedChannel).
                // Safe no-op guard: if nothing was captured at .began, do nothing.
                guard let capturedSource = self.interruptedSource else {
                    self.log.log("Interruption ended but no captured source — safe no-op", category: .interruption)
                    self.isRidingOutInterruption = false
                    return
                }

                if self.isRidingOutInterruption {
                    // Short interruption — VLC stayed alive with its internal cache.
                    // Just reactivate the audio session so VLC can output again.
                    self.isRidingOutInterruption = false
                    self.interruptedChannel = nil
                    self.interruptedSource = nil
                    self.interruptedQueueAPI = nil
                    self.interruptedElapsedSeconds = nil

                    switch capturedSource {
                    case .radio(let channel):
                        self.log.log("Short interruption ended — reactivating audio session for radio \"\(channel.name)\"", category: .interruption)
                        // Delay to let the audio route settle (CarPlay route transitions
                        // need time to switch back from phone/Siri to media output).
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            let session = AVAudioSession.sharedInstance()
                            // Cycle through deactivate to clear the stale route
                            // that the interruption left behind, then go through
                            // assertSessionOwnership for the activate side — that
                            // helper also restarts AVAudioEngine, which iOS will
                            // have stopped when the session went inactive.
                            do {
                                try session.setActive(false, options: .notifyOthersOnDeactivation)
                                self.log.log("Short interruption: session deactivated to clear stale route", category: .audioSession)
                            } catch {
                                self.log.log("Short interruption: session deactivate FAILED: \(error.localizedDescription)", category: .audioSession)
                            }
                            self.assertSessionOwnership(context: "short interruption")

                            // Check if VLC survived the interruption
                            let vlcAlive = self.isActiveSession && (self.mediaPlayer.isPlaying || self.mediaPlayer.state == .buffering || self.mediaPlayer.state == .opening)
                            self.log.log("VLC post-interruption: alive=\(vlcAlive), state=\(self.vlcStateName(self.mediaPlayer.state)), isPlaying=\(self.mediaPlayer.isPlaying)", category: .interruption)

                            if vlcAlive {
                                // VLC is fine — nothing else to do, audio resumes from cache
                                self.log.log("VLC survived interruption — seamless resume", category: .interruption)
                            } else {
                                // VLC died during the interruption — cold restart
                                self.log.log("VLC died during interruption — cold restarting \"\(channel.name)\"", category: .interruption)
                                self.play(channel: channel, userInitiated: false)
                            }

                            // Diagnostic: watch the session for a few seconds after
                            // we resume.  If a phone call is still active, it should
                            // reclaim audio here — the window the original log never
                            // captured.  Instrumentation only (beads_mobilemusic-lfn).
                            self.probePostResumeAudio(context: "short-interruption", channel: channel)
                        }

                    case .library(let queue, let index):
                        self.log.log("Short interruption ended — reactivating audio session for library track index=\(index)", category: .interruption)
                        // Library short interruption: same session reactivation as radio,
                        // then check if VLC survived.  If not, cold-restart the track.
                        let savedAPI = self.interruptedQueueAPI ?? self.queueAPI
                        let savedElapsed = self.interruptedElapsedSeconds
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            let session = AVAudioSession.sharedInstance()
                            do {
                                try session.setActive(false, options: .notifyOthersOnDeactivation)
                                self.log.log("Short interruption (library): session deactivated to clear stale route", category: .audioSession)
                            } catch {
                                self.log.log("Short interruption (library): session deactivate FAILED: \(error.localizedDescription)", category: .audioSession)
                            }
                            self.assertSessionOwnership(context: "short interruption library")

                            let vlcAlive = self.isActiveSession && (self.mediaPlayer.isPlaying || self.mediaPlayer.state == .buffering || self.mediaPlayer.state == .opening)
                            self.log.log("VLC post-interruption (library): alive=\(vlcAlive), state=\(self.vlcStateName(self.mediaPlayer.state)), isPlaying=\(self.mediaPlayer.isPlaying)", category: .interruption)

                            if vlcAlive {
                                self.log.log("VLC survived library interruption — seamless resume at index=\(index)", category: .interruption)
                            } else {
                                self.log.log("VLC died during library interruption — cold restarting track at index=\(index)", category: .interruption)
                                guard let api = savedAPI, index < queue.count else {
                                    self.log.log("Library interruption resume: missing API or index out of bounds — safe no-op", category: .interruption)
                                    return
                                }
                                self.startLibraryTrack(queue[index], inQueue: queue, at: index, via: api)
                                // Seek to saved position after a brief delay for VLC to buffer.
                                if let elapsed = savedElapsed, elapsed > 0 {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                        let ms = Int32(exactly: max(0, elapsed * 1000).rounded()) ?? Int32(max(0, elapsed * 1000))
                                        self.mediaPlayer.time = VLCTime(int: ms)
                                        self.log.log("Library interruption resume: seeked to \(String(format: "%.1f", elapsed))s", category: .interruption)
                                    }
                                }
                            }
                        }
                    }

                } else {
                    // Long interruption — fallback already stopped VLC (and started
                    // time-shift capture for radio).  Dispatch on source type.
                    self.interruptedChannel = nil
                    self.interruptedSource = nil
                    self.interruptedQueueAPI = nil
                    self.interruptedElapsedSeconds = nil

                    switch capturedSource {
                    case .radio(let channel):
                        // Existing time-shift buffer path — unchanged.
                        let bufferFileURL = self.timeShiftBuffer.stopCapture()
                        self.log.log("Time-shift buffer: \(bufferFileURL != nil ? "available" : "none")", category: .interruption)
                        self.log.log("Scheduling 500ms delayed restart for radio \"\(channel.name)\"", category: .interruption)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            self.reactivateAndPlay(channel: channel, bufferFileURL: bufferFileURL)
                        }

                    case .library(let queue, let index):
                        // d6q.8: library long interruption — VLC was stopped by
                        // the fallback; no time-shift buffer is involved.
                        // Restart the track at the captured index and seek to
                        // the saved position.
                        let savedAPI = self.interruptedQueueAPI
                        let savedElapsed = self.interruptedElapsedSeconds
                        self.log.log("Scheduling 500ms delayed restart for library track index=\(index)", category: .interruption)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            guard let api = savedAPI, index < queue.count else {
                                self.log.log("Library long-interruption resume: missing API or index OOB — safe no-op", category: .interruption)
                                return
                            }
                            self.reactivateAndPlayLibraryTrack(queue[index], inQueue: queue, at: index, via: api, seekTo: savedElapsed)
                        }
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
        play(channel: channel, userInitiated: false)
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

    /// Diagnostic probe: after we resume from an interruption, sample the audio
    /// session a few times over the next several seconds.  The original
    /// CarPlay-during-call report (beads_mobilemusic-lfn) could not be confirmed
    /// because nothing logged whether another audio source (a phone call) was
    /// still active *after* we reactivated.  If a call reclaims audio here, the
    /// route/otherAudio/silenceHint will shift in these samples.
    ///
    /// Instrumentation only — does NOT change resume behavior.
    private func probePostResumeAudio(context: String, channel: Channel) {
        // Sample at +1s, +3s, +6s after resume.
        for delay in [1.0, 3.0, 6.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                let session = AVAudioSession.sharedInstance()
                let outputs = session.currentRoute.outputs.map { "\($0.portName) (\($0.portType.rawValue))" }.joined(separator: ", ")
                self.log.log("PostResumeProbe[\(context)] +\(Int(delay))s: otherAudio=\(session.isOtherAudioPlaying), silenceHint=\(session.secondaryAudioShouldBeSilencedHint), vlcState=\(self.vlcStateName(self.mediaPlayer.state)), vlcPlaying=\(self.mediaPlayer.isPlaying), outputs=[\(outputs)], channel=\"\(channel.name)\"", category: .interruption)
            }
        }
    }

    private func reactivateAndPlay(channel: Channel, bufferFileURL: URL? = nil) {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.map { "\($0.portName) (\($0.portType.rawValue))" }.joined(separator: ", ")
        log.log("reactivateAndPlay: channel=\"\(channel.name)\", buffer=\(bufferFileURL != nil), outputs=[\(outputs)]", category: .audioSession)

        // Unconditionally cycle deactivate→activate to release the stale
        // audio route (CarPlay/Siri/phone-call interruptions leave VLC
        // unable to reconnect otherwise) AND restart the AVAudioEngine
        // that the deactivation will have stopped.  Routing through the
        // helper keeps the engine-restart logic in one place.
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            log.log("reactivateAndPlay: session deactivated to clear stale route", category: .audioSession)
        } catch {
            log.log("reactivateAndPlay: session deactivate FAILED: \(error.localizedDescription)", category: .audioSession)
        }
        assertSessionOwnership(context: "reactivateAndPlay")

        if let bufferFileURL {
            playBufferedFile(bufferFileURL, for: channel)
        } else {
            play(channel: channel, userInitiated: false)
        }
    }

    // MARK: - Interruption capture/restore helpers (d6q.8)

    /// Snapshot of the player state at interruption .began.
    /// Extracted into a named struct so unit tests can exercise the
    /// capture logic without instantiating a live audio session.
    struct InterruptionSnapshot {
        let source: PlaybackSource
        /// NavidromeAPI retained for library-track URL construction.
        /// Nil for radio sources.
        let queueAPI: NavidromeAPI?
        /// VLC elapsed position at capture (seconds ≥ 0), nil if unknown.
        let elapsedSeconds: Double?
    }

    /// Captures the current playback state into an `InterruptionSnapshot`.
    ///
    /// Called at AVAudioSession interruption `.began` to record what should
    /// be restored when the interruption ends.  Returns `nil` if nothing is
    /// playing (safe no-op guard).
    ///
    /// This method is `internal` (not `private`) so unit tests can call it
    /// directly and assert snapshot contents.
    func captureInterruptionSnapshot() -> InterruptionSnapshot? {
        guard let source = playbackSource else { return nil }
        // VLC elapsed: intValue is -1 when unknown; clamp to nil.
        let vlcMs = mediaPlayer.time.intValue
        let elapsed: Double? = vlcMs > 0 ? Double(vlcMs) / 1000.0 : nil
        // queueAPI is only meaningful for library sources.
        let api: NavidromeAPI? = {
            if case .library = source { return queueAPI }
            return nil
        }()
        return InterruptionSnapshot(source: source, queueAPI: api, elapsedSeconds: elapsed)
    }

    /// Reactivates the audio session and cold-restarts a library track, then
    /// seeks to `elapsedSeconds` (if available and > 0) after a brief buffer
    /// delay.
    ///
    /// Mirrors `reactivateAndPlay(channel:bufferFileURL:)` for the library path.
    private func reactivateAndPlayLibraryTrack(
        _ track: Track,
        inQueue queue: [Track],
        at index: Int,
        via api: NavidromeAPI,
        seekTo elapsedSeconds: Double?
    ) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            log.log("reactivateAndPlayLibraryTrack: session deactivated to clear stale route", category: .audioSession)
        } catch {
            log.log("reactivateAndPlayLibraryTrack: session deactivate FAILED: \(error.localizedDescription)", category: .audioSession)
        }
        assertSessionOwnership(context: "reactivateAndPlayLibraryTrack")
        startLibraryTrack(track, inQueue: queue, at: index, via: api)
        // Seek to saved position after VLC has had time to buffer.
        // A 1-second delay is heuristic; VLC needs to parse the media
        // before time-setting is honoured.
        if let elapsed = elapsedSeconds, elapsed > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                let ms = Int32(exactly: max(0, elapsed * 1000).rounded()) ?? Int32(max(0, elapsed * 1000))
                self.mediaPlayer.time = VLCTime(int: ms)
                self.log.log("Library interruption resume: seeked to \(String(format: "%.1f", elapsed))s after restart", category: .interruption)
            }
        }
    }

    // MARK: - Playback

    /// - Parameter userInitiated: `true` for an explicit user action (channel
    ///   tap, next/prev, Play/resume) — only these may pull audio focus away
    ///   from another app or an active phone call.  `false` for automatic
    ///   plays (network-path reconnects, retries, interruption recovery): these
    ///   must never seize the session from other audio; they defer and retry
    ///   once it releases.  See beads_mobilemusic-lfn.
    public func play(channel: Channel, userInitiated: Bool = true) {
        // A fresh play() supersedes any deferred automatic reconnect.
        deferredReconnectWorkItem?.cancel()
        deferredReconnectWorkItem = nil
        // Don't tear down an active stream to restart the same channel.
        // During CarPlay reconnect, multiple PLAY commands and channel
        // selections can fire within seconds — each would needlessly
        // destroy and recreate the VLC player for no benefit.
        //
        // But only skip when playback is GENUINELY alive.  After a long
        // interruption (Siri / read-aloud), the session can be left wedged:
        // isActiveSession stays true while VLC has stopped or the render
        // engine was stopped by a route change.  In that state a bare PLAY
        // or re-selecting the same station must rebuild the stream rather
        // than be swallowed here — otherwise the only recovery is switching
        // to a different channel.
        let vlcLooksAlive = mediaPlayer.isPlaying
            || mediaPlayer.state == .buffering
            || mediaPlayer.state == .opening
        if channel.id == currentChannel?.id, isActiveSession,
           vlcLooksAlive, AudioOutput.shared.isRunning {
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

        // Take audio focus from any other app currently producing audio
        // (Apple Music, podcast app, etc.).  No-op when otherAudio is
        // already false (typical channel change), so this is essentially
        // a cold-start hook.  The amem pipeline keeps VLC from touching
        // the session at all, so we only need the explicit takeover at
        // the moment of first-play; channel-to-channel transitions never
        // release ownership in the first place.
        //
        // An automatic play must NOT pull focus from other audio here — an
        // incoming call's cellular-path flap can fire a reconnect, and seizing
        // the session would deactivate the call's audio.  Defer the takeover to
        // startStream's guard, which re-checks after the debounce.
        if userInitiated || !AVAudioSession.sharedInstance().isOtherAudioPlaying {
            assertSessionOwnership(context: "play(): takeover")
        } else {
            log.log("play(): takeover skipped — automatic play while other audio active", category: .audioSession)
        }

        let channelChanged = currentChannel?.id != channel.id
        currentChannel = channel
        playbackSource = .radio(channel)   // d6q.7: mirror into PlaybackSource seam
        // d6q.5: disable scrubber for radio (live streams are not seekable).
        updateRemoteCommandsForSource(playbackSource)
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
            self.startStream(for: channel, userInitiated: userInitiated)
        }
        pendingPlayWorkItem = workItem

        if needsDelay {
            log.log("Debouncing 1.5s before starting stream", category: .player)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
        } else {
            workItem.perform()
        }
    }

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

    // MARK: - Auto-advance (d6q.3)

    /// Advance the library queue after a natural track-end event.
    ///
    /// This is the single decision point that fires when VLC reports `.ended`
    /// for a `.library` track.  It is intentionally separate from
    /// `playNextInQueue()` (which is the user-gesture / remote-command path)
    /// so that **d6q.4 (repeat mode)** can intercept here without touching the
    /// public next/previous API.
    ///
    /// **d6q.4 seam — how to wire repeat:**
    /// When d6q.4 is built, add a `repeatMode` property (default `.off`) and
    /// branch at the top of this method:
    ///   - `.one`  → `startLibraryTrack(currentTrack, ...)` to restart in place
    ///   - `.all`  → wrap the index (nextIndex % queue.count) before calling
    ///               `startLibraryTrack`
    ///   - `.off`  → the existing `playNextInQueue()` behaviour below
    ///
    /// **Runaway-advance guard:**
    /// `advance()` is only called from the `.ended` branch in `syncState()`,
    /// which fires exclusively when VLC reaches the natural end of a finite
    /// media file.  The `.error` and `.stopped` branches are explicitly
    /// excluded — they do NOT call `advance()` — so a track that fails to
    /// start (network error, bad URL) leaves the queue stopped rather than
    /// spinning through every track.  No additional rate-limiter is needed
    /// because `.ended` can only fire once per media lifecycle; a second fire
    /// on the same player instance would require VLC to reach end-of-media
    /// again, which cannot happen after `startLibraryTrack` has retired the
    /// player.
    ///
    /// **d6q.9 — Gapless / inter-track gap findings:**
    /// The current architecture tears down the VLCMediaPlayer instance
    /// (`retirePlayer`) on every track transition.  The measured gap is
    /// approximately 200–500 ms of silence (network-caching fill + new VLC
    /// instance init + amem bridge attach).  Three alternatives were considered:
    ///
    /// 1. `VLCMediaListPlayer` — MobileVLCKit 3.6.0 exposes this class.  It
    ///    maintains an internal VLCMediaPlayer and advances between VLCMediaList
    ///    items automatically.  However, it does NOT use the amem (custom audio
    ///    output) bridge — it owns its own audio unit, which would bypass the
    ///    AVAudioEngine pipeline entirely and break the audio session ownership
    ///    model, the wedge watchdog, and the ring-buffer path the rest of the app
    ///    depends on.  **Not viable without a major architecture change.**
    ///
    /// 2. Reuse VLCMediaPlayer across tracks (swap media without `retirePlayer`)
    ///    — VLCKit's `mediaPlayer.media = newMedia; mediaPlayer.play()` without
    ///    full teardown is plausible in theory, but the existing `retirePlayer`
    ///    comment documents that omitting `pthread_join` (via background disposal)
    ///    caused 0x8BADF00D watchdog kills.  A half-measure that stops but does
    ///    not background-dispose the old instance risks that same stall.
    ///    Additionally, the amem bridge (`VLCAudioCallbackBridge.attachAudioCallbacks`)
    ///    is designed to be attached once per player instance; re-attaching on
    ///    a live player is untested.  **Risky without a dedicated spike.**
    ///
    /// 3. Accept the gap — the ~200–500 ms silence is audible but tolerable for
    ///    album playback.  Most users expect a brief gap between tracks.  This
    ///    is not significantly worse than typical Bluetooth latency.
    ///
    /// **Recommendation:** Accept the gap at this stage (option 3).  A proper
    /// gapless implementation would require either a second VLC instance
    /// pre-buffering the next track during the final seconds of the current one
    /// (double-buffering), or a dedicated spike to validate reusing
    /// VLCMediaPlayer without retire.  File as a follow-up task (d6q gapless
    /// improvement) when the basic queue playback is proven stable.
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
    private func advance() {
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
    /// Uses a fire-and-forget `Task` to avoid blocking the caller.  The write
    /// is idempotent and cheap; no error handling is needed — if it fails the
    /// in-memory value is still correct for the current session.
    private func persistQueuePreferences() {
        Task {
            var settings = await PersistenceService.shared.loadOrDefault(
                from: Constants.StorageKeys.settings, default: AppSettings.default
            )
            settings.repeatMode = self.repeatMode
            settings.shuffleEnabled = self.shuffleEnabled
            try? await PersistenceService.shared.save(settings, to: Constants.StorageKeys.settings)
        }
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

    private func fireSubmissionScrobbleIfNeeded(trackID: String, via api: NavidromeAPI) {
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

    private func startLibraryTrack(
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
        // Artist for now-playing: prefer per-track value once tracks carry their
        // own denormalised name; fall back to the queue-level display artist.
        currentTrackArtistName = queueDisplayArtistName
        nowPlayingSubtitle = queueDisplayArtistName   // bug hzl: in-app player subtitle
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
        stateTimer = Timer.scheduledTimer(withTimeInterval: fastPollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.syncState()
            }
        }
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
    private func updateNowPlayingInfoForTrack() {
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

        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = state

        let stateName: String
        switch state {
        case .playing: stateName = "playing"
        case .paused:  stateName = "paused"
        default:       stateName = "other"
        }
        log.log("NowPlaying (track): title=\"\(title)\", artist=\"\(artist)\", isLive=false, state=\(stateName), elapsed=\(String(format: "%.1f", elapsed))s, duration=\(duration.map { String(format: "%.1f", $0) } ?? "nil")s, rate=\(rate)", category: .player)
    }

    /// Deactivate→reactivate the session so iOS formally hands audio focus
    /// to Adagio.  A bare setActive(true) is a no-op when the session is
    /// already active, which leaves remote-command registration with
    /// whichever app held focus previously — steering-wheel next/prev then
    /// routes there instead of us.  Only runs the deactivate step when
    /// another app currently holds focus; otherwise this is a cheap no-op.
    ///
    /// CRITICAL: setActive(false) on a session that AVAudioEngine is bound
    /// to causes the engine to stop, and setActive(true) does NOT
    /// auto-restart it.  This helper restarts AudioOutput at the end so
    /// every caller gets a working engine on return.  Same applies to a
    /// bare setActive(true) — an earlier interruption may have stopped
    /// the engine without our knowledge, so the resilient restart is
    /// always worth running.
    @discardableResult
    private func assertSessionOwnership(context: String) -> Bool {
        let session = AVAudioSession.sharedInstance()
        let otherPlaying = session.isOtherAudioPlaying
        // 46u: stuck-flag safety — every deliberate-play path that comes
        // through here must be allowed to start the engine regardless of
        // notification balance (unmatched .began with no .ended).
        AudioOutput.shared.clearInterruptionGateForDeliberatePlay()
        do {
            if otherPlaying {
                try session.setActive(false, options: .notifyOthersOnDeactivation)
                log.log("\(context): session deactivated to take over from other app", category: .audioSession)
            }
            try session.setActive(true)
            log.log("\(context): session active (otherWasPlaying=\(otherPlaying))", category: .audioSession)
            AudioOutput.shared.start()
            return otherPlaying
        } catch {
            log.log("\(context): session takeover FAILED: \(error.localizedDescription)", category: .audioSession)
            // Try to bring the engine back regardless — the session may
            // still be usable even if the cycle errored.
            AudioOutput.shared.start()
            return false
        }
    }

    /// End any active background task requested for buffering timeout.
    /// No-op on tvOS — the iOS background-task model doesn't apply there.
    private func endBufferingBackgroundTask() {
        #if os(iOS)
        if bufferingBackgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(bufferingBackgroundTaskID)
            bufferingBackgroundTaskID = .invalid
        }
        #endif
    }

    /// Re-attempt an automatic reconnect that was deferred because other audio
    /// (an active phone call, a nav prompt, another media app) owned the
    /// session.  Polls `isOtherAudioPlaying` once a second; fires the play as
    /// soon as that audio releases, or gives up after
    /// `deferredReconnectMaxAttempts` seconds (channel stays set for a manual
    /// resume).  Aborts if the user has since moved to a different channel.
    private func scheduleDeferredReconnect(for channel: Channel, attempt: Int = 0) {
        deferredReconnectWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.currentChannel?.id == channel.id else {
                self.log.log("Deferred reconnect aborted — channel changed from \"\(channel.name)\"", category: .player)
                return
            }
            if AVAudioSession.sharedInstance().isOtherAudioPlaying {
                if attempt >= self.deferredReconnectMaxAttempts {
                    self.log.log("Deferred reconnect gave up for \"\(channel.name)\" — other audio still active after \(self.deferredReconnectMaxAttempts)s", category: .audioSession)
                    return
                }
                self.scheduleDeferredReconnect(for: channel, attempt: attempt + 1)
                return
            }
            self.log.log("Deferred reconnect firing for \"\(channel.name)\" — other audio released", category: .audioSession)
            self.play(channel: channel, userInitiated: false)
        }
        deferredReconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func startStream(for channel: Channel, userInitiated: Bool) {
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
            interruptedSource = nil        // d6q.8
            interruptedQueueAPI = nil      // d6q.8
            interruptedElapsedSeconds = nil // d6q.8
            interruptionFallbackWorkItem?.cancel()
            interruptionFallbackWorkItem = nil
        }
        // An automatic reconnect/retry must never seize the session from other
        // audio.  This is the reliable guard point: it runs after play()'s
        // debounce, by which time an incoming call's audio has actually engaged
        // (isOtherAudioPlaying becomes true ~1s after the path flap that
        // triggered the reconnect).  Seizing here is exactly what played music
        // over a live call (beads_mobilemusic-lfn).  Defer and retry instead.
        if !userInitiated, AVAudioSession.sharedInstance().isOtherAudioPlaying {
            log.log("startStream deferred: other audio owns the session during an automatic reconnect for \"\(channel.name)\" — not seizing", category: .audioSession)
            isActiveSession = false
            isBuffering = false
            scheduleDeferredReconnect(for: channel)
            return
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
        #if os(iOS)
        bufferingBackgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "StreamBuffering") { [weak self] in
            self?.endBufferingBackgroundTask()
        }
        #endif

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
        // Render-block counters are cumulative-since-launch by default;
        // resetting at stream start makes per-stream underrun rate
        // observable (otherwise the buffering window's natural empty-
        // ring underruns dominate the signal).
        VLCAudioCallbackBridge.resetRenderCounters()

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
                        self.startStream(for: channel, userInitiated: false)
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
        interruptedSource = nil        // d6q.8
        interruptedQueueAPI = nil      // d6q.8
        interruptedElapsedSeconds = nil // d6q.8
        interruptionTime = nil
        timeShiftBuffer.cancelAndCleanup()

        play(channel: channel, userInitiated: false)
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
        // Update the correct now-playing surface: library tracks need elapsed/rate
        // cleared to 0 immediately on pause so the scrubber doesn't keep advancing.
        if currentTrack != nil {
            updateNowPlayingInfoForTrack()
        } else {
            updateNowPlayingInfo()
        }

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
        interruptedSource = nil        // d6q.8
        interruptedQueueAPI = nil      // d6q.8
        interruptedElapsedSeconds = nil // d6q.8
        interruptionTime = nil
        stop()
    }

    public func stop() {
        log.log("stop() channel=\"\(currentChannel?.name ?? "nil")\"", category: .player)
        // Note: do NOT clear interruptedChannel / interruptedSource here —
        // stop() is called by the interruption handler after saving the source
        // to resume.  Only pause() and play() should clear them (explicit user
        // actions).  The d6q.8 fields (interruptedSource, interruptedQueueAPI,
        // interruptedElapsedSeconds) follow the same rule.
        isRidingOutInterruption = false
        interruptionFallbackWorkItem?.cancel()
        interruptionFallbackWorkItem = nil
        // A stop cancels any pending automatic reconnect so it can't resurrect
        // playback after the user (or the system) has stopped.
        deferredReconnectWorkItem?.cancel()
        deferredReconnectWorkItem = nil
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
        currentTrack = nil                 // d6q.2: clear track state on stop
        currentTrackArtwork = nil
        currentTrackArtistName = nil
        nowPlayingSubtitle = nil           // bug hzl: clear in-app player subtitle
        nowPlayingArtworkURL = nil         // clear in-app player artwork on stop
        currentQueueIndex = nil            // d6q.1: clear queue index on stop
        queueAPI = nil
        queueDisplayArtistName = nil
        shuffleOrder = []                  // d6q.4: clear shuffle state on stop
        shufflePosition = 0
        trackElapsed = 0.0                 // d6q.6: clear scrubber on stop
        trackDuration = nil
        playbackSource = nil               // d6q.7: mirror into PlaybackSource seam
        // d6q.5: disable scrubber when no source is active.
        updateRemoteCommandsForSource(nil)
        isPlaying = false
        isBuffering = false
        currentArtwork = nil
        sxmArtwork = nil
        if interruptedChannel != nil {
            // Interruption — keep polling so track history stays current.
            // Leave the AVAudioEngine's intent intact: we expect to resume,
            // and the config-change observer should still follow route flips.
            interruptionTime = Date()
            sxmService.suspendForTimeShift()
        } else {
            // Genuine stop (user stop or CarPlay disconnect) — tear the render
            // engine down too. Without this the config-change observer restarts
            // it on the post-stop route change and leaves it running idle,
            // which reads as "the session never ended" (bd tpu).
            interruptionTime = nil
            bufferPlaybackStartedAt = nil
            sxmService.stopPolling()
            AudioOutput.shared.stop()
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
                    startStream(for: channel, userInitiated: false)
                }
                // Timeout: if buffering too long with no meaningful data, retry with smaller buffer
                else if let start = streamStartTime, !hasReceivedData,
                   Date().timeIntervalSince(start) > bufferingTimeoutInterval,
                   !isReducedBufferRetry,
                   let channel = currentChannel {
                    log.log("Buffering timeout (\(Int(bufferingTimeoutInterval))s with no data) — retrying with reduced buffer (\(Int(reducedBufferDuration))s), channel=\"\(channel.name)\"", category: .player)
                    isReducedBufferRetry = true
                    lastLoggedVLCState = nil
                    startStream(for: channel, userInitiated: false)
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
                    // Time-shift buffer path (radio): clean up and chain to next
                    // buffer or reconnect live.  Unchanged from pre-d6q.3.
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
                        play(channel: channel, userInitiated: false)
                    }
                } else if case .library = playbackSource {
                    // d6q.3: Library track reached natural end-of-media.
                    //
                    // Branch on playbackSource so radio streams are never
                    // touched here.  Live radio doesn't reach .ended under
                    // normal operation; if it somehow does (e.g. a server
                    // terminates the connection cleanly), the `else if`
                    // guard ensures we fall through to `default` and let
                    // existing radio reconnect / probe logic handle it.
                    //
                    // Runaway-advance guard: we call advance() ONLY on
                    // .ended (genuine track completion), never on .error or
                    // .stopped.  If a track fails to start, VLC will report
                    // .stopped or .error — those branches set an error
                    // message and leave the queue halted.  See the advance()
                    // doc-comment for the full guard rationale.
                    //
                    // 65x.1: Natural end-of-track counts as sufficient play;
                    // fire the submission scrobble if not already sent.
                    if let track = currentTrack, let api = queueAPI {
                        fireSubmissionScrobbleIfNeeded(trackID: track.id, via: api)
                    }
                    log.log("Library track ended naturally — auto-advancing queue (d6q.3)", category: .player)
                    advance()
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

        // 65x.1: Scrobble submission threshold check — library only.
        // Runs every timer tick so even a final tick just before .ended can
        // satisfy the threshold.  The `scrobbler.submissionSent` guard ensures
        // exactly one submission per track play.
        if case .library = playbackSource,
           let track = currentTrack,
           let api = queueAPI,
           isPlaying {
            let elapsed = Double(mediaPlayer.time.intValue > 0 ? mediaPlayer.time.intValue : 0) / 1000.0
            let duration: Double? = {
                let vlcMs = mediaPlayer.media?.length.intValue ?? 0
                if vlcMs > 0 { return Double(vlcMs) / 1000.0 }
                if let d = track.duration, d > 0 { return Double(d) }
                return nil
            }()
            if AudioPlayerService.scrobbleShouldSubmit(elapsed: elapsed, duration: duration) {
                fireSubmissionScrobbleIfNeeded(trackID: track.id, via: api)
            }
        }

        updateStreamStats()
        // Dispatch to the correct now-playing updater based on playback mode.
        if currentTrack != nil {
            updateNowPlayingInfoForTrack()
        } else {
            updateNowPlayingInfo()
        }

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
        lastNowPlayingElapsed = nil
        if currentTrack != nil {
            updateNowPlayingInfoForTrack()
        } else {
            updateNowPlayingInfo()
        }
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
    private func updateRemoteCommandsForSource(_ source: PlaybackSource?) {
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
            Task { @MainActor in
                guard let self else { return }
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
