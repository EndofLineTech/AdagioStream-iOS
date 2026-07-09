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
    internal let log = DebugLogger.shared

    /// beads_mobilemusic-t96.3: the single owner of `AppSettings` — set once
    /// by `SettingsViewModel.init`. `persistQueuePreferences()` routes writes
    /// through it instead of doing its own independent load-modify-save, which
    /// previously raced `SettingsViewModel.saveSettings()` for the same file.
    weak var settingsViewModel: SettingsViewModel?

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

    /// True when anything is playing that warrants the mini-player: a radio/
    /// library `nowPlaying` item OR an Audiobookshelf book (audiobooks are a
    /// separate path with no `nowPlaying` item — yu8.1/yu8.4).
    public var hasActivePlayback: Bool {
        nowPlaying != nil || currentAudiobook != nil
    }

    @Published public var isPlaying = false
    @Published public var isBuffering = false
    @Published public var error: String?
    @Published public var streamBitrateKbps: Double = 0
    @Published public var statusText: String = ""
    @Published public var streamTitle: String?
    @Published public var streamArtist: String?
    /// Use `listeningStartDate` and `accumulatedListeningTime` to compute duration in views.
    public internal(set) var listeningStartDate: Date?
    public internal(set) var accumulatedListeningTime: TimeInterval = 0

    public let timeShiftBuffer = TimeShiftBufferService.shared
    public let sxmService = SXMMetadataService.shared

    internal var mediaPlayer = VLCMediaPlayer()
    private var sxmCancellable: AnyCancellable?
    private var espnCancellable: AnyCancellable?
    internal var stateTimer: Timer?

    // MARK: - Wedge watchdog (bd a14)
    // Diagnostic-only. Samples the render pipeline every few seconds while we
    // believe audio is playing. If VLC reports playing but the AVAudioEngine
    // is dead or its render thread is frozen, the stream is silently wedged —
    // the unrecoverable CarPlay/Siri state that leaves no crash dump. We log a
    // full snapshot so the next field capture is unambiguous; no behavior change.
    internal var wedgeWatchdogTimer: Timer?
    internal var lastRenderCallSample = 0
    internal var lastPlayCallbackSample = 0
    internal var wedgeSuspectSince: Date?
    internal let fastPollInterval: TimeInterval = 0.5
    private let slowPollInterval: TimeInterval = 3.0
    private let backgroundPollInterval: TimeInterval = 10.0
    internal var currentPollInterval: TimeInterval = 0.5
    private var isInBackground = false
    internal var currentArtwork: MPMediaItemArtwork?
    internal var sxmArtwork: MPMediaItemArtwork?
    /// The track being played in `.library` mode; nil when in radio mode.
    internal var currentTrack: Track?

    // MARK: - Scrobble state (65x.1)

    /// Scrobble state + fire helpers.  Extracted to Scrobbler.swift; AudioPlayerService
    /// owns the instance and delegates reset/fire calls to it.
    internal let scrobbler = Scrobbler()

    /// Human-readable artist display name threaded in from the album context
    /// by `play(track:displayArtistName:via:)`.  Used to build the lock-screen
    /// now-playing info (`updateNowPlayingInfoForTrack`).
    /// Cleared each time a new track starts so stale names never bleed through.
    internal var currentTrackArtistName: String?

    /// Published mirror of `currentTrackArtistName` for the in-app mini/full
    /// player subtitle (bug hzl).  `Track.displaySubtitle` is nil (it only knows
    /// `artistId`), so the player reads this for the library subtitle instead of
    /// the now-playing item.  Nil when nothing is playing, in radio mode, or when
    /// no display artist was threaded (e.g. playlist/search playback).
    @Published public internal(set) var nowPlayingSubtitle: String?

    /// Resolved cover-art URL for the currently-playing library track, for the
    /// in-app mini/full player artwork (bug rendering).  `Track.artworkURL` is nil
    /// (the model can't build an authed getCoverArt URL without an API context),
    /// so the player reads this instead.  Built from `track.coverArt` via the
    /// queue API at track start; nil in radio mode or when the track has no art.
    @Published public internal(set) var nowPlayingArtworkURL: URL?

    /// Artwork loaded for the currently-playing track (cover art from Navidrome).
    internal var currentTrackArtwork: MPMediaItemArtwork?

    // MARK: - Audiobook playback state (Audiobookshelf E2 / yu8.2)

    /// Active audiobook session, or nil when not playing an audiobook.
    ///
    /// Audiobooks are a SELF-CONTAINED playback path — not shoehorned into the
    /// `.library` Track queue, which is Navidrome-coupled (scrobbles, cover-art
    /// URLs, stream URLs at every step). This holder carries everything the
    /// audiobook path needs: the timeline (global↔file math), the ABS API for
    /// progress sync, and the current file being fed to VLC. The player reuses
    /// the same VLC primitives (retirePlayer, amem bridge, state timer, .ended
    /// chaining) as radio and library tracks.
    internal var audiobookSession: AudiobookSession?

    /// Book-global playback position in seconds. Published for the UI (chapter
    /// display, scrubber). 0 when no audiobook is playing.
    @Published public internal(set) var audiobookGlobalTime: Double = 0

    /// Total duration of the current book in seconds; nil when none is playing.
    @Published public internal(set) var audiobookDuration: Double?

    /// The book currently playing (for the mini/full player), or nil.
    @Published public internal(set) var currentAudiobook: Audiobook?

    /// The current chapter, derived from `audiobookGlobalTime`. nil when none.
    @Published public internal(set) var currentChapter: AudiobookChapter?

    // MARK: - Queue state (d6q.1)

    /// The index of the currently-playing track within the `.library` queue.
    /// Nil when in radio mode or when nothing is playing.
    @Published public internal(set) var currentQueueIndex: Int?

    // MARK: - Elapsed + Duration (d6q.6)

    /// Current playback position in seconds for the active library track.
    /// 0.0 when in radio mode or when no track is playing.
    /// Updated every timer tick (0.5–3s) from VLC; the UI seek bar reads this
    /// and uses its own local @State while scrubbing so it doesn't fight the timer.
    @Published public internal(set) var trackElapsed: Double = 0.0

    /// Duration in seconds of the active library track.
    /// Nil when unknown (radio, or library track whose duration is not yet parsed).
    /// Sourced first from VLC's parsed media length; falls back to `Track.duration`.
    @Published public internal(set) var trackDuration: Double? = nil

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
    internal var shuffleOrder: [Int] = []

    /// Cursor into `shuffleOrder` pointing at the currently-playing track.
    /// Undefined when `shuffleEnabled == false`.
    internal var shufflePosition: Int = 0

    /// The display artist name that applies to every track in the current
    /// library queue (e.g. the album artist).  Stored alongside the queue so
    /// it carries forward as next/previous advance the index.
    /// Per-track artist is preferred if the track itself exposes one; this
    /// value is the queue-level fallback when the track's own subtitle is
    /// just an `artistId`.
    internal var queueDisplayArtistName: String?

    /// The NavidromeAPI instance in use for the current library queue.
    /// Retained so `playNextInQueue()` and `playPreviousInQueue()` can build
    /// stream URLs without the UI having to re-supply `api` on every call.
    internal var queueAPI: NavidromeAPI?

    /// The ordered list of `Track` objects in the current library queue.
    /// Derived from `playbackSource` so it is always in sync with the
    /// authoritative state.  Returns `[]` when in radio mode.
    public var currentLibraryQueue: [Track] {
        guard case .library(let queue, _) = playbackSource else { return [] }
        return queue
    }
    private var lastPlayedChannel: Channel?
    internal var interruptedChannel: Channel?

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
    internal var interruptedSource: PlaybackSource?
    internal var interruptedQueueAPI: NavidromeAPI?
    internal var interruptedElapsedSeconds: Double?

    // Gates the wedge watchdog (see startWedgeWatchdog/stopWedgeWatchdog): the
    // watchdog only matters while we intend to be playing, which is exactly
    // what this flag already tracks (it stays true through interruption
    // ride-out — see handleAudioInterruption — since the wedge detector exists
    // precisely for stuck-during-intended-playback states).
    internal var isActiveSession = false {
        didSet {
            guard isActiveSession != oldValue else { return }
            if isActiveSession {
                startWedgeWatchdog()
            } else {
                stopWedgeWatchdog()
            }
        }
    }
    private var lastToggleTime: Date = .distantPast
    internal var lastLoggedVLCState: VLCMediaPlayerState?
    internal var channelChangeRetryCount = 0
    internal var vlcZeroByteRetryCount = 0
    internal let maxVLCZeroByteRetries = 5
    internal var streamProbeTask: URLSessionDataTask?
    internal var probeStartTime: Date?
    internal let probeTimeout: TimeInterval = 45
    internal var lastProbeHTTPStatus: Int?
    internal var pendingPlayWorkItem: DispatchWorkItem?
    /// True when `pendingPlayWorkItem` was scheduled by a reconnect path that
    /// is holding the shared reconnect guard (beads_mobilemusic-t96.26).  The
    /// guard must survive play()'s debounce, not just the synchronous call —
    /// this flag is how cancellation (a fresh play() superseding the pending
    /// one) knows to release the guard it would otherwise leak.
    internal var pendingPlayOwnsReconnectGuard = false
    internal var channelNameOverlayActive = false
    private var channelNameOverlayWorkItem: DispatchWorkItem?
    internal var lastTeardownTime: Date = .distantPast
    internal var isPlayingBufferedFile = false
    internal var streamStartTime: Date?
    internal var wasAwaitingInitialBuffer = false
    internal var hasReceivedData = false
    internal var isReducedBufferRetry = false
    private let bufferingTimeoutInterval: TimeInterval = 20
    private let reducedBufferDuration: TimeInterval = 3
    /// Last decoded audio frame count observed with active data flow.
    internal var lastActiveDecodedAudio: Int32 = 0
    /// Tracked for detecting mid-stream buffer loss (audio blips).
    internal var lastLoggedLostAudioBuffers: Int32 = 0
    internal var lastLoggedDiscontinuity: Int32 = 0
    /// When data flow was last seen (demux or input bitrate > 0).
    internal var lastDataFlowTime: Date?
    /// How long data flow can be absent before triggering auto-reconnect.
    private let dataFlowStaleTimeout: TimeInterval = 8
    #if os(iOS)
    private var bufferingBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    #endif
    internal var lastNowPlayingTitle: String?
    internal var lastNowPlayingArtist: String?
    internal var lastNowPlayingIsLive: Bool?
    internal var lastNowPlayingRate: Double?
    internal var lastNowPlayingState: MPNowPlayingPlaybackState?
    internal var lastNowPlayingArtwork: MPMediaItemArtwork?
    /// Last elapsed time (seconds) written to MPNowPlayingInfoCenter for change-detection.
    /// nil when in radio mode or nothing is playing.
    internal var lastNowPlayingElapsed: Double?
    internal var bufferedChannel: Channel?
    internal var currentBufferFileURL: URL?
    internal var interruptionTime: Date?
    internal var bufferPlaybackStartedAt: Date?
    /// True while an audio session interruption is active and VLC is being
    /// kept alive (short-interruption path).  Suppresses syncState reactions.
    internal var isRidingOutInterruption = false
    /// Fires when a short interruption exceeds bufferDuration, falling back
    /// to the old stop-and-capture path.
    internal var interruptionFallbackWorkItem: DispatchWorkItem?
    /// Diagnostic counters for began/ended pairing.  A Siri-initiated call can
    /// post multiple .began with a single .ended; the asymmetry is a clue that
    /// another interruption (e.g. an active call) is still outstanding when we
    /// resume.  Instrumentation only — see beads_mobilemusic-lfn.
    internal var interruptionBeganCount = 0
    internal var interruptionEndedCount = 0
    // ponytail: intentionally permanent, never cancelled. Cost is one OS
    // network-state subscription. `networkPathSummary` (below) exposes
    // `lastPathStatus` to SettingsViewModel's debug snapshot independent of
    // playback state, so this can't be gated to "intended playback" the way
    // the wedge watchdog is — a paused user opening the debug snapshot would
    // see a stale "unknown" instead of live network status.
    internal var pathMonitor: NWPathMonitor?
    internal let pathMonitorQueue = DispatchQueue(label: "com.adagiostream.pathmonitor")
    internal var lastPathStatus: NWPath.Status?
    internal var lastPrimaryInterface: NWInterface.InterfaceType?
    internal var lastPathReconnectTime: Date = .distantPast
    /// Minimum interval between path-monitor-triggered reconnects.  A subway
    /// or tower handoff can fire several path events in quick succession;
    /// without a cooldown we'd tear down and rebuild the player repeatedly.
    internal let pathReconnectCooldown: TimeInterval = 5
    /// Pending retry for an automatic reconnect that was deferred because
    /// other audio (a phone call, a nav prompt, another media app) owned the
    /// session at takeover time.  Polls until that audio releases.
    internal var deferredReconnectWorkItem: DispatchWorkItem?
    /// How long an automatic reconnect keeps waiting for other audio to
    /// release before giving up (leaving the channel set for manual resume).
    internal let deferredReconnectMaxAttempts = 90

    /// beads_mobilemusic-t96.4: shared in-flight guard across the four
    /// independent reconnect/retry paths (path-monitor force-play, deferred
    /// reconnect, probe-and-retry, watchdog restart) — generalizes
    /// `pathReconnectCooldown` so only one path owns a reconnect attempt at a
    /// time and they don't tear down/rebuild the VLC player concurrently.
    /// Set when a path claims an attempt; cleared on that attempt's
    /// completion, failure, or timeout. `reconnectGuardStaleAfter` is a
    /// staleness escape so a bug that forgets to clear the flag can't wedge
    /// recovery forever.
    internal var reconnectInFlightSince: Date?
    /// Longest bound of any single retry path (deferred reconnect polls for
    /// up to `deferredReconnectMaxAttempts` seconds) plus margin. A guard
    /// older than this is treated as stale/abandoned and ignored.
    internal let reconnectGuardStaleAfter: TimeInterval = 120

    public var channels: [Channel] = []
    public var bufferDuration: TimeInterval = Constants.defaultBufferDuration
    public var artworkDisplayMode: ArtworkDisplayMode = .coverArt

    /// Run `block` and log how long it took.  Used to stamp every VLC
    /// teardown call so a future main-thread stall leaves an unambiguous
    /// fingerprint: the 0x8BADF00D scene-update watchdog gives us 10 s
    /// before SIGKILL, and without per-call timing we cannot tell from the
    /// log alone which call burned the budget.
    @discardableResult
    internal func timed<T>(_ name: String, _ block: () -> T) -> T {
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
    internal func retirePlayer(options: [String]? = nil) {
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

    // MARK: - Playback

    /// - Parameter userInitiated: `true` for an explicit user action (channel
    ///   tap, next/prev, Play/resume) — only these may pull audio focus away
    ///   from another app or an active phone call.  `false` for automatic
    ///   plays (network-path reconnects, retries, interruption recovery): these
    ///   must never seize the session from other audio; they defer and retry
    ///   once it releases.  See beads_mobilemusic-lfn.
    public func play(channel: Channel, userInitiated: Bool = true) {
        // A fresh play() supersedes any deferred automatic reconnect. That
        // reconnect holds the shared guard across its poll chain (claimed
        // once at attempt 0) — cancelling it here without releasing would
        // leak the claim until the staleness escape kicks in
        // (beads_mobilemusic-t96.26).
        if deferredReconnectWorkItem != nil {
            deferredReconnectWorkItem?.cancel()
            deferredReconnectWorkItem = nil
            releaseReconnectGuard()
        }
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
            // A reconnect path may have claimed the guard before calling in —
            // no work item is scheduled on this early-return path, so release
            // here or the claim leaks until the staleness escape kicks in.
            if !userInitiated {
                releaseReconnectGuard()
            }
            return
        }

        log.log("play() channel=\"\(channel.name)\" group=\"\(channel.group)\" url=\(channel.streamURL.redactedForLog)", category: .player)

        // Cancel any pending stream start from a previous rapid channel tap.
        // If that pending start was a reconnect path's debounced play, this
        // supersedes it — release the guard here so the superseding call
        // (user tap or a newer reconnect) never gets blocked by a claim whose
        // owner just got cancelled (beads_mobilemusic-t96.26).
        pendingPlayWorkItem?.cancel()
        pendingPlayWorkItem = nil
        if pendingPlayOwnsReconnectGuard {
            pendingPlayOwnsReconnectGuard = false
            releaseReconnectGuard()
        }
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

        // A reconnect path (path-monitor / deferred-reconnect) claims the
        // shared guard before calling play(:userInitiated: false). Carry
        // that ownership through the debounce so the guard stays held until
        // startStream() actually runs, instead of being released the moment
        // this synchronous call returns — closing the cross-path collision
        // window the guard exists to prevent (beads_mobilemusic-t96.26).
        // A user-initiated call never claims the guard, so this is always
        // false for a manual tap regardless of guard state.
        let ownsReconnectGuard = Self.playCallOwnsReconnectGuard(userInitiated: userInitiated, reconnectInFlightSince: reconnectInFlightSince)
        pendingPlayOwnsReconnectGuard = ownsReconnectGuard

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            defer {
                if ownsReconnectGuard {
                    self.pendingPlayOwnsReconnectGuard = false
                    self.releaseReconnectGuard()
                }
            }
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

    internal func startStream(for channel: Channel, userInitiated: Bool) {
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
        startStateTimer(interval: fastPollInterval)
    }
    /// End any active background task requested for buffering timeout.
    /// No-op on tvOS — the iOS background-task model doesn't apply there.
    internal func endBufferingBackgroundTask() {
        #if os(iOS)
        if bufferingBackgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(bufferingBackgroundTaskID)
            bufferingBackgroundTaskID = .invalid
        }
        #endif
    }
    /// Called when the app enters/leaves the background.
    public func setBackgroundMode(_ background: Bool) {
        isInBackground = background
        // Audiobookshelf E2 (yu8.3): flush progress when backgrounding so the
        // server has an up-to-date position if the app is suspended.
        if background, audiobookSession != nil { syncAudiobookProgress(force: true) }
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
        startStateTimer(interval: interval)
    }

    /// (Re)starts the polling fallback timer that calls `syncState()` — VLC's
    /// delegate fires on a background thread that can miss MainActor updates.
    /// Invalidates any existing timer first.
    internal func startStateTimer(interval: TimeInterval) {
        stateTimer?.invalidate()
        stateTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.syncState()
            }
        }
    }
    public func pause() {
        log.log("pause() channel=\"\(currentChannel?.name ?? "nil")\"", category: .player)
        // Audiobookshelf E2: flush a progress sync before the stream pauses.
        if audiobookSession != nil { pauseAudiobook() }
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
        if audiobookSession != nil {
            updateNowPlayingInfoForAudiobook()
        } else if currentTrack != nil {
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
        // Audiobookshelf E2: a paused audiobook reloads its current file at the
        // saved book-global position (pause() called mediaPlayer.stop()).
        if let session = audiobookSession,
           let located = session.timeline.locate(global: audiobookGlobalTime) {
            log.log("resume() audiobook \"\(session.book.title)\" @\(String(format: "%.1f", audiobookGlobalTime))s", category: .player)
            loadAudiobookFile(located.file, fileOffset: located.fileOffset)
            return
        }

        // bug 9nf: pause() leaves playbackSource/queueAPI untouched (only
        // stop() clears them), so a paused library track is still
        // identifiable here. Without this check resume() fell through to
        // currentChannel ?? lastPlayedChannel — always nil/stale radio state
        // while a library track is paused — and restarted the last radio
        // station instead of the track.
        if case .library(let queue, let index) = playbackSource,
           let api = queueAPI, index < queue.count {
            let track = queue[index]
            log.log("resume() library track=\"\(track.title)\" index=\(index)", category: .player)
            reactivateAndPlayLibraryTrack(track, inQueue: queue, at: index, via: api, seekTo: trackElapsed)
            return
        }

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
        // Audiobookshelf E2: close the server session (releases transcode
        // resources) and clear audiobook state. stopAudiobook is a no-op when
        // no audiobook is playing.
        if audiobookSession != nil { stopAudiobook() }
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

    // MARK: - State Sync

    internal func syncState() {
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
                    if claimReconnectGuard(path: "watchdog-silent-dropout") {
                        log.log("Silent dropout detected — no data flow for \(Int(dataFlowStaleTimeout))s after \(lastActiveDecodedAudio) decoded frames, reconnecting channel=\"\(channel.name)\"", category: .player)
                        lastLoggedVLCState = nil
                        isReducedBufferRetry = false
                        startStream(for: channel, userInitiated: false)
                        releaseReconnectGuard()
                    }
                }
                // Timeout: if buffering too long with no meaningful data, retry with smaller buffer
                else if let start = streamStartTime, !hasReceivedData,
                   Date().timeIntervalSince(start) > bufferingTimeoutInterval,
                   !isReducedBufferRetry,
                   let channel = currentChannel {
                    if claimReconnectGuard(path: "watchdog-buffering-timeout") {
                        log.log("Buffering timeout (\(Int(bufferingTimeoutInterval))s with no data) — retrying with reduced buffer (\(Int(reducedBufferDuration))s), channel=\"\(channel.name)\"", category: .player)
                        isReducedBufferRetry = true
                        lastLoggedVLCState = nil
                        startStream(for: channel, userInitiated: false)
                        releaseReconnectGuard()
                    }
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
                            // Claim the guard once, at the true start of a probe chain
                            // (probeStartTime nil). Recursive re-probes inside
                            // probeAndRetryStream already hold it.
                            if probeStartTime == nil, claimReconnectGuard(path: "probe-and-retry") {
                                probeStartTime = Date()
                                if let channel = currentChannel {
                                    probeAndRetryStream(for: channel)
                                }
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
                } else if audiobookSession != nil {
                    // Audiobookshelf E2: a book file finished — chain to the next
                    // file on the global timeline, or close the session at end.
                    audiobookFileEnded()
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
        if audiobookSession != nil {
            tickAudiobook()
            updateNowPlayingInfoForAudiobook()
        } else if currentTrack != nil {
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

}
