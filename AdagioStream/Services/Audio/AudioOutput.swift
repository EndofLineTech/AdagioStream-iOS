import AVFoundation
import Foundation

/// Owns the AVAudioEngine that renders PCM produced by VLC (via the
/// VLCAudioCallbackBridge ring buffer) to the device's audio output.
///
/// This is the Swift end of the amem pipeline.  VLC's audio thread
/// writes decoded float32 stereo samples into the bridge's ring
/// buffer; the AVAudioSourceNode's render block pulls from the same
/// buffer on the audio I/O thread.  AdagioStream owns the
/// AVAudioSession exclusively — VLC's audiounit_ios module is never
/// loaded, so VLC can't deactivate the session under us.
///
/// The engine is started once at app init and stays running for the
/// app's lifetime.  Streams come and go (each new VLCMediaPlayer
/// gets its callbacks attached separately), but the engine itself
/// keeps draining the ring buffer continuously.  When VLC is between
/// streams or paused, the ring buffer is empty and the source node
/// outputs silence.
public final class AudioOutput {
    public static let shared = AudioOutput()

    // Pinned format: AVAudioEngine consumes 48kHz stereo float32
    // interleaved, VLC's amem is told to produce exactly this via
    // libvlc_audio_set_format("FL32", 48000, 2).  No resampling or
    // de-interleaving is required between the two sides.
    public static let sampleRate: UInt32 = 48000
    public static let channelCount: UInt32 = 2

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var configChangeObserver: NSObjectProtocol?
    private let log = DebugLogger.shared

    /// Whether the caller currently intends audio to be playing.  The
    /// AVAudioEngineConfigurationChange observer only resurrects the engine
    /// while this is true — otherwise a post-stop route change (e.g. CarPlay
    /// disconnect handing the route back to the phone speaker) would restart
    /// the engine and leave it running idle, which reads to the user as "the
    /// session never ended".  Set true by start(), cleared by stop().
    private var intendedToRun = false

    /// Whether an AVAudioSession interruption (e.g. Siri reading a text) is
    /// currently in effect.  Set TRUE by `noteInterruptionBegan()`, cleared
    /// to FALSE by `noteInterruptionEnded()`.
    ///
    /// The config-change handler MUST NOT restart the engine while this is
    /// true: during ride-out the app keeps VLC running with `intendedToRun`
    /// still set, so the only additional gate between a harmless config-change
    /// and ~2 s of audible audio leak over Siri is this flag.
    ///
    /// Stuck-flag safety: every deliberate-play path (reactivateAndPlay,
    /// play(channel:), startLibraryTrack, assertSessionOwnership) also
    /// clears this flag so that an unbalanced began/ended sequence can never
    /// permanently block the engine.
    ///
    /// Exposed read-only (beads_mobilemusic-cpr kickback, Block 2) so callers
    /// outside this file — CarPlay reconnect-resume — can gate on the SAME
    /// self-healing signal 46u already relies on, instead of comparing
    /// AudioPlayerService's interruptionBeganCount/interruptionEndedCount
    /// (which are never reset and would latch permanently on one dropped
    /// `.ended`, a documented-common occurrence on CarPlay disconnect).
    public private(set) var isInterrupted = false

    /// When the currently-latched `isInterrupted` gate went up, tracked
    /// independently of AudioPlayerService's `interruptedChannel`/
    /// `interruptionTime` — those fields get nil'd by
    /// `stopAndClearInterruption()` on CarPlay disconnect, which can happen
    /// mid-interruption. If the `.ended` notification is then dropped (a
    /// documented-common occurrence on CarPlay disconnect —
    /// CarPlaySceneDelegate.swift), `interruptedChannel` alone can no longer
    /// prove staleness on reconnect. This timestamp survives that cleanup
    /// so `healStaleInterruptionGateIfNeeded` still has evidence to heal
    /// from (beads_mobilemusic-irg). Set by `noteInterruptionBegan()`,
    /// cleared by `noteInterruptionEnded()`, `clearInterruptionGateForDeliberatePlay()`,
    /// and the heal itself.
    private var interruptionBeganAt: Date?

    /// Set when `stopAndClearInterruption()` (CarPlay disconnect) ran while
    /// `isInterrupted` was still true — the exact, documented case where the
    /// `.ended` notification is at risk of being dropped. This is the ONLY
    /// evidence the heal below is allowed to act on the drop actually
    /// happening; `interruptionBeganAt` alone proves an interruption started
    /// long ago, but says nothing about whether THIS was the CarPlay-disconnect
    /// scenario or an ordinary still-running interruption (e.g. a phone call
    /// that ride-out silently stopped audio for at ~bufferDuration — review
    /// finding on beads_mobilemusic-irg round 1: playback state after ride-out
    /// is identical in the stale and still-active cases by design, so it
    /// cannot be the proof). Cleared by `noteInterruptionEnded()` (interruption
    /// ended normally, no drop occurred) and `clearInterruptionGateForDeliberatePlay()`
    /// (gate already resolved by a fresh deliberate play).
    private var interruptionEndedDropRisk = false

    /// Number of consecutive engine.start() failures since the last success.
    /// A sustained streak means the engine is wedged (iOS won't let us bind
    /// the route) — the signature of the unrecoverable CarPlay/Siri wedge.
    private var consecutiveStartFailures = 0

    /// Whether the render engine is actually running.  Callers use this to
    /// distinguish a genuinely-live session from a wedged one (engine stopped
    /// under us by iOS) without relying on higher-level flags.
    public var isRunning: Bool { engine.isRunning }

    /// Consecutive start-failure count, surfaced for the wedge watchdog's
    /// diagnostic snapshot.
    public var startFailureStreak: Int { consecutiveStartFailures }

    private init() {
        // NON-INTERLEAVED (planar) float32.  iOS's AU buses only accept
        // planar formats on input; trying to connect an AVAudioSourceNode
        // configured with interleaved=true crashes inside
        // AUInterfaceBaseV3::SetFormat with an NSException.  The bridge
        // de-interleaves on the C side as it pulls from the ring buffer,
        // so this format mismatch with VLC's FL32 interleaved output is
        // resolved zero-copy on the audio thread.
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: Double(Self.sampleRate),
                                          channels: AVAudioChannelCount(Self.channelCount),
                                          interleaved: false) else {
            log.log("AudioOutput: failed to construct AVAudioFormat", category: .audioSession)
            return
        }

        let node = AVAudioSourceNode(format: format) { isSilence, _, frameCount, audioBufferList -> OSStatus in
            // REAL-TIME audio I/O thread.  No allocations, no Swift
            // locks, no Obj-C dispatch beyond the C-bridged pull.
            VLCAudioCallbackBridge.reportRenderCall()
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard abl.count >= 2,
                  let leftData = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let rightData = abl[1].mData?.assumingMemoryBound(to: Float.self) else {
                isSilence.pointee = ObjCBool(true)
                return noErr
            }
            let requested = Int(frameCount)
            let pulled = VLCAudioCallbackBridge.pullFrames(intoLeft: leftData,
                                                           right: rightData,
                                                           maxFrames: requested)

            if pulled < requested {
                // Underrun (or stream paused / between channels) —
                // zero-fill the tail of each channel so the render
                // block doesn't emit uninitialised memory.
                let zeroCount = requested - pulled
                let zeroBytes = zeroCount * MemoryLayout<Float>.size
                memset(leftData.advanced(by: pulled), 0, zeroBytes)
                memset(rightData.advanced(by: pulled), 0, zeroBytes)
                VLCAudioCallbackBridge.reportUnderrun()
            }
            isSilence.pointee = ObjCBool(pulled == 0)
            return noErr
        }
        sourceNode = node

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)

        // Follow hardware route/format changes.  AVAudioEngine STOPS itself
        // when the output format changes — e.g. CarPlay switching from the
        // Siri/phone voice route (24 kHz mono) back to the media route
        // (48 kHz stereo) after an interruption.  If we don't restart here,
        // the engine that was started against the transient voice route stays
        // dead: VLC keeps filling the ring buffer but nobody drains it, so the
        // stream is "playing" with no audio.  Restart to rebind to the new route.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Use the pure predicate so the restart decision is testable
            // independently of the live engine/session.
            guard AudioOutput.shouldRestartEngineOnConfigChange(
                intendedToRun: self.intendedToRun,
                isInterrupted: self.isInterrupted
            ) else {
                if self.isInterrupted {
                    self.log.log("AudioOutput: configuration changed while interrupted — not restarting (intendedToRun=\(self.intendedToRun), isInterrupted=true)", category: .audioSession)
                } else {
                    self.log.log("AudioOutput: configuration changed while idle — not restarting (intendedToRun=false)", category: .audioSession)
                }
                return
            }
            self.log.log("AudioOutput: engine configuration changed (route/format) — restarting engine", category: .audioSession)
            self.performStart()
        }
    }

    deinit {
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
        }
    }

    /// Idempotent.  Checks engine.isRunning directly (rather than a
    /// cached flag) because iOS can stop the engine under us — for
    /// example when the audio session is deactivated during a pause —
    /// without us getting a chance to update local state.  Calling
    /// start() after that path correctly resumes audio output.
    public func start() {
        intendedToRun = true
        performStart()
    }

    /// The actual engine-start work, shared by the public start() and the
    /// configuration-change observer.  Does NOT touch intendedToRun, so the
    /// observer can restart a wanted engine without changing intent.
    private func performStart() {
        guard sourceNode != nil else { return }
        if engine.isRunning { return }
        do {
            try engine.start()
            // Surface the hardware output format the engine actually
            // bound to.  If this doesn't match our source node format
            // (48 kHz stereo float32), AVAudioEngine has inserted an
            // implicit converter and any rate mismatch will show up as
            // pitch artifacts that point straight at the cause.
            let mixerOut = engine.mainMixerNode.outputFormat(forBus: 0)
            let mixerIn  = engine.mainMixerNode.inputFormat(forBus: 0)
            let outputFmt = engine.outputNode.outputFormat(forBus: 0)
            log.log("AudioOutput: engine started, source=Float32 planar \(Self.sampleRate)Hz \(Self.channelCount)ch | mixer.in=\(Int(mixerIn.sampleRate))Hz/\(mixerIn.channelCount)ch | mixer.out=\(Int(mixerOut.sampleRate))Hz/\(mixerOut.channelCount)ch | hwOut=\(Int(outputFmt.sampleRate))Hz/\(outputFmt.channelCount)ch", category: .audioSession)
            if consecutiveStartFailures > 0 {
                log.log("AudioOutput: engine recovered after \(consecutiveStartFailures) consecutive start failure(s)", category: .audioSession)
            }
            consecutiveStartFailures = 0
        } catch {
            consecutiveStartFailures += 1
            log.log("AudioOutput: engine.start() FAILED (streak=\(consecutiveStartFailures)): \(error.localizedDescription)", category: .audioSession)
            // A sustained streak while we still intend to play is the wedge
            // fingerprint — flag it loudly so the next field log makes the
            // unrecoverable state unambiguous.
            if consecutiveStartFailures >= 3 {
                log.log("AudioOutput: WEDGE — engine.start() failed \(consecutiveStartFailures)x in a row while intendedToRun=\(intendedToRun); render pipeline is starved", category: .audioSession)
            }
        }
    }

    public func stop() {
        intendedToRun = false
        guard engine.isRunning else { return }
        engine.stop()
        log.log("AudioOutput: engine stopped", category: .audioSession)
    }

    // MARK: - Mute (bug 8jq)

    /// Silences/restores the mixer output without touching engine or session
    /// state. Used to hide the brief "plays from position 0" blip while a
    /// library-track resume seeks to its saved position — see
    /// `reactivateAndPlayLibraryTrack` in AudioPlayerService.
    public func setMuted(_ muted: Bool) {
        engine.mainMixerNode.outputVolume = muted ? 0 : 1
    }

    // MARK: - Interruption gate (46u)

    /// Called by AudioPlayerService when AVAudioSession interruption .began
    /// fires.  Suppresses any engine restart triggered by the route/format
    /// change that Siri or a phone call fires while it takes over the session.
    public func noteInterruptionBegan() {
        isInterrupted = true
        interruptionBeganAt = Date()
        log.log("AudioOutput: interruption began — engine restart suppressed during ride-out", category: .audioSession)
    }

    /// Called by AudioPlayerService when AVAudioSession interruption .ended
    /// fires.  Clears the gate so the engine can restart on the next
    /// config-change or deliberate start.
    public func noteInterruptionEnded() {
        isInterrupted = false
        interruptionBeganAt = nil
        interruptionEndedDropRisk = false
        log.log("AudioOutput: interruption ended — engine restart gate cleared", category: .audioSession)
    }

    /// Called by `AudioPlayerService.stopAndClearInterruption()` when CarPlay
    /// disconnects. Records the drop-risk evidence the heal predicate below
    /// requires: `stopAndClearInterruption()` nils AudioPlayerService's
    /// `interruptedChannel`/`interruptionTime` unconditionally, whether or not
    /// the interruption that's still latched here is actually over — this is
    /// the moment that ambiguity is created, so it's the moment to record it.
    /// No-op when nothing is currently interrupted (a plain disconnect with no
    /// interruption in flight has no drop risk to flag).
    public func noteInterruptionDropRisk() {
        guard isInterrupted else { return }
        interruptionEndedDropRisk = true
        log.log("AudioOutput: interruption drop-risk recorded (stopAndClearInterruption ran while still interrupted)", category: .audioSession)
    }

    /// Called by every deliberate-play path (assertSessionOwnership,
    /// play(channel:), startLibraryTrack) as a stuck-flag safety net.
    ///
    /// The field log shows `unmatchedBegans` up to 3: if an `.ended`
    /// notification is never delivered, `isInterrupted` would remain true
    /// forever and the engine would never restart.  This override guarantees
    /// that any intentional user/app-initiated play clears the gate
    /// unconditionally.  Only logs when the flag was actually set (no noise
    /// on the normal path).
    public func clearInterruptionGateForDeliberatePlay() {
        guard isInterrupted else { return }
        isInterrupted = false
        interruptionBeganAt = nil
        interruptionEndedDropRisk = false
        log.log("AudioOutput: interruption gate cleared by deliberate-play path (was stuck from unmatched .began)", category: .audioSession)
    }

    // MARK: - Stale-gate heal (beads_mobilemusic-irg)

    /// Heals a latched `isInterrupted` gate — but ONLY when there is evidence
    /// that distinguishes "the `.ended` was dropped" from "the interruption is
    /// still running". Round 1 of this fix tried to prove staleness from
    /// elapsed time + playback state alone; the review proved that inference
    /// false for an ordinary >30s phone call: the ride-out fallback stops
    /// playback at ~bufferDuration (~8s) while the call is still active, so by
    /// 31s in, `elapsed > 30 && !isPlaying && !isBuffering` all hold for a
    /// call that has NOT ended — playback state after ride-out is identical
    /// in the stale and still-active cases by design. Healing on that alone
    /// let CarPlay reconnect-resume start playback over a live call (46u,
    /// converted from fails-safe to fails-dangerous).
    ///
    /// The proof now requires BOTH:
    ///   1. `interruptionEndedDropRisk` — recorded by `noteInterruptionDropRisk()`
    ///      only when `stopAndClearInterruption()` (CarPlay disconnect) ran
    ///      while still interrupted, i.e. the actual documented `.ended`-
    ///      dropping event. Without this flag, elapsed time and idle playback
    ///      prove nothing — an ordinary long ride-out looks identical, and the
    ///      heal must not fire.
    ///   2. A live probe (`AVAudioSession.isOtherAudioPlaying`, read at heal
    ///      time and passed into the pure predicate as `foreignAudioDetected`)
    ///      — the drop-risk flag alone still false-heals if CarPlay reconnects
    ///      while the call is STILL active (disconnect mid-call → reconnect
    ///      mid-call, no `.ended` yet). `isOtherAudioPlaying` is validated
    ///      ground truth for "another app/call currently owns the session" in
    ///      THIS app: beads_mobilemusic-lfn confirmed it true during a live
    ///      cellular call via a since-removed CallKit-backed diagnostic
    ///      (build 162), and production already gates automatic reconnects on
    ///      it unconditionally (`scheduleDeferredReconnect`,
    ///      `AudioPlayerService.play()`/`startStream()` takeover-skip) — this
    ///      heal uses the exact same, already-trusted signal. China-safe: no
    ///      CallKit in this path, matching beads_mobilemusic-ylb.
    ///
    /// The existing elapsed/not-playing/not-buffering/not-riding-out checks
    /// stay as secondary guards (unchanged 30s threshold and rationale from
    /// round 1) — they just no longer stand in as sole proof.
    ///
    /// No-op (never heals) when the drop-risk flag isn't set, elapsed time is
    /// short, playback/ride-out is active, or the probe finds foreign audio —
    /// any of those leaves open the possibility the interruption is still
    /// genuinely active (the 46u constraint: never clear isInterrupted while
    /// that's possible).
    @discardableResult
    public func healStaleInterruptionGateIfNeeded(isPlaying: Bool, isBuffering: Bool, isRidingOutInterruption: Bool) -> Bool {
        let elapsed = interruptionBeganAt.map { Date().timeIntervalSince($0) }
        let foreignAudioDetected = AVAudioSession.sharedInstance().isOtherAudioPlaying
        guard Self.shouldHealStaleInterruptionGate(
            isInterrupted: isInterrupted,
            dropRiskFlagSet: interruptionEndedDropRisk,
            elapsedSinceBegan: elapsed,
            isPlaying: isPlaying,
            isBuffering: isBuffering,
            isRidingOutInterruption: isRidingOutInterruption,
            foreignAudioDetected: foreignAudioDetected
        ) else { return false }

        log.log("AudioOutput: healing stale interruption gate (\(Int(elapsed ?? 0))s since began, drop-risk flag set, no foreign audio detected — beads_mobilemusic-irg)", category: .audioSession)
        isInterrupted = false
        interruptionBeganAt = nil
        interruptionEndedDropRisk = false
        return true
    }

    /// Pure predicate behind `healStaleInterruptionGateIfNeeded`, extracted
    /// so unit tests can cover every combination without instantiating
    /// AudioOutput (constructing `AudioOutput.shared` deadlocks the
    /// simulator's CoreAudio in the test target — see
    /// AudioOutputRestartPredicateTests.swift) and without a live
    /// AVAudioSession (`foreignAudioDetected` is passed in as a plain Bool —
    /// the probe itself is read by the caller). Mirrors the shape of
    /// `shouldRestartEngineOnConfigChange`.
    static func shouldHealStaleInterruptionGate(
        isInterrupted: Bool,
        dropRiskFlagSet: Bool,
        elapsedSinceBegan: TimeInterval?,
        isPlaying: Bool,
        isBuffering: Bool,
        isRidingOutInterruption: Bool,
        foreignAudioDetected: Bool
    ) -> Bool {
        guard isInterrupted, dropRiskFlagSet, let elapsed = elapsedSinceBegan else { return false }
        guard elapsed > 30, !isPlaying, !isBuffering, !isRidingOutInterruption else { return false }
        return !foreignAudioDetected
    }

    // MARK: - Pure restart predicate (testable)

    /// Returns `true` when the AVAudioEngineConfigurationChange handler should
    /// restart the engine.  Extracted as a static pure function so unit tests
    /// can cover every combination without instantiating AudioOutput or
    /// touching the live AVAudioEngine / AVAudioSession.
    ///
    /// Contract: restart only when the app intends to play AND no interruption
    /// is currently in effect.  The idle guard (`intendedToRun == false`) was
    /// already present before this change; the interruption guard is new (46u).
    static func shouldRestartEngineOnConfigChange(intendedToRun: Bool, isInterrupted: Bool) -> Bool {
        return intendedToRun && !isInterrupted
    }
}
