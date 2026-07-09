import AVFoundation
import MediaPlayer
@preconcurrency import VLCKitSPM
#if os(iOS)
import UIKit
#endif

// beads_mobilemusic-t96.14: mechanical split of AudioPlayerService along MARK
// boundaries. Zero behavior change from the pre-split file. Audio session
// configuration, interruption/route-change handling, and the wedge watchdog.
extension AudioPlayerService {
    // MARK: - Wedge Watchdog

    /// Started when `isActiveSession` flips true (intended playback begins)
    /// and stopped when it flips false, so the timer isn't armed for the
    /// process lifetime — see the `isActiveSession` didSet.
    internal func startWedgeWatchdog() {
        wedgeWatchdogTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkAudioHealth() }
        }
        timer.tolerance = 1.0
        wedgeWatchdogTimer = timer
    }

    internal func stopWedgeWatchdog() {
        wedgeWatchdogTimer?.invalidate()
        wedgeWatchdogTimer = nil
        wedgeSuspectSince = nil
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

    internal func configureAudioSession() {
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
    internal func reactivateAndPlayLibraryTrack(
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

        // bug 8jq: startLibraryTrack() below plays from position 0 immediately;
        // the seek to the saved position only lands after the heuristic delay
        // below, so real audio flows from the track's start in the meantime.
        // Mute across that window so the listener only hears the seeked-to
        // position, not a blip of the intro.
        let hasSeek = (elapsedSeconds ?? 0) > 0
        if hasSeek {
            AudioOutput.shared.setMuted(true)
        }
        startLibraryTrack(track, inQueue: queue, at: index, via: api)
        // Seek to saved position after VLC has had time to buffer.
        // A 1-second delay is heuristic; VLC needs to parse the media
        // before time-setting is honoured.
        if let elapsed = elapsedSeconds, elapsed > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                let ms = Int32(exactly: max(0, elapsed * 1000).rounded()) ?? Int32(max(0, elapsed * 1000))
                self.mediaPlayer.time = VLCTime(int: ms)
                // Drop any pre-seek samples already sitting in the ring buffer
                // so the render thread doesn't play a stray frame from position 0.
                VLCAudioCallbackBridge.flushBuffer()
                self.log.log("Library interruption resume: seeked to \(String(format: "%.1f", elapsed))s after restart", category: .interruption)
                // Give the buffer a brief moment to refill from the new
                // position before unmuting.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    AudioOutput.shared.setMuted(false)
                }
            }
        }
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
    internal func assertSessionOwnership(context: String) -> Bool {
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
}
