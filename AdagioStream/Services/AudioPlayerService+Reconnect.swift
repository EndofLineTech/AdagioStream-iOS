import AVFoundation
import Network

// beads_mobilemusic-t96.14: mechanical split of AudioPlayerService along MARK
// boundaries. Zero behavior change from the pre-split file. Reconnect
// coordination guard, network path monitor, and the probe/retry + deferred
// reconnect paths.
extension AudioPlayerService {
    // MARK: - Reconnect Coordination Guard (beads_mobilemusic-t96.4)

    /// Pure decision: may a reconnect path claim the shared in-flight guard
    /// right now? Extracted from instance state so it's testable without a
    /// live player. `nil` means no attempt is currently claimed. A non-nil
    /// `claimedAt` older than `staleAfter` is treated as an abandoned guard
    /// (e.g. a path that crashed/was deallocated before clearing it) and no
    /// longer blocks new attempts.
    nonisolated static func canClaimReconnectGuard(
        claimedAt: Date?,
        now: Date,
        staleAfter: TimeInterval
    ) -> Bool {
        guard let claimedAt else { return true }
        return now.timeIntervalSince(claimedAt) > staleAfter
    }

    /// Attempts to claim the shared reconnect guard for `path`. Returns
    /// `false` (and logs) if another path already owns an in-flight attempt.
    /// Callers must call `releaseReconnectGuard()` when their attempt
    /// completes, fails, or times out.
    internal func claimReconnectGuard(path: String) -> Bool {
        let now = Date()
        guard Self.canClaimReconnectGuard(claimedAt: reconnectInFlightSince, now: now, staleAfter: reconnectGuardStaleAfter) else {
            log.log("Reconnect guard held — \(path) suppressed (in flight since \(reconnectInFlightSince.map { String(format: "%.0f", now.timeIntervalSince($0)) } ?? "?")s ago)", category: .player)
            return false
        }
        reconnectInFlightSince = now
        return true
    }

    internal func releaseReconnectGuard() {
        reconnectInFlightSince = nil
    }

    /// Pure decision: does this call to `play(channel:userInitiated:)` own
    /// the shared reconnect guard, and must therefore carry it through
    /// play()'s debounce instead of the guard being released when the
    /// synchronous call returns? (beads_mobilemusic-t96.26)
    ///
    /// A user-initiated call never claims the guard itself — regardless of
    /// whether some other reconnect attempt happens to be in flight, a
    /// manual tap must never be gated, delayed, or treated as a guard owner.
    /// An automatic call only owns the guard if one is actually held (the
    /// caller — path-monitor or deferred-reconnect — claimed it just before
    /// calling in).
    nonisolated static func playCallOwnsReconnectGuard(
        userInitiated: Bool,
        reconnectInFlightSince: Date?
    ) -> Bool {
        !userInitiated && reconnectInFlightSince != nil
    }

    /// beads_mobilemusic-crr: pure decision — must a path-monitor-driven
    /// reconnect stand down because an audio-session interruption is in
    /// progress? Either signal suffices: `ridingOut` covers the short
    /// ride-out window, `interruptedSourceActive` covers the long path
    /// (fallback already stopped VLC, source captured awaiting .ended).
    /// The interruption handler owns the resume decision in both windows.
    nonisolated static func shouldSuppressPathReconnect(
        ridingOut: Bool,
        interruptedSourceActive: Bool
    ) -> Bool {
        ridingOut || interruptedSourceActive
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
    internal func configureNetworkPathMonitor() {
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

        // beads_mobilemusic-crr: while an interruption is in progress (riding
        // out, or a source captured awaiting .ended), the interruption handler
        // owns the resume decision. A network transition during a car-off
        // interruption (cellular→wifi as the user walks inside) must not
        // restart playback on the phone speaker. Deliberately NOT gated on
        // isActiveSession — a dead stream with network back is this feature's
        // legitimate case.
        if AudioPlayerService.shouldSuppressPathReconnect(
            ridingOut: isRidingOutInterruption,
            interruptedSourceActive: interruptedSource != nil
        ) {
            log.log("Path-driven reconnect suppressed — interruption in progress owns the resume decision", category: .player)
            return
        }

        let elapsed = Date().timeIntervalSince(lastPathReconnectTime)
        if elapsed < pathReconnectCooldown {
            log.log("Path-driven reconnect suppressed — \(String(format: "%.1f", elapsed))s since last (cooldown \(Int(pathReconnectCooldown))s)", category: .player)
            return
        }

        guard claimReconnectGuard(path: "path-monitor") else { return }
        // Ownership of the guard transfers into play(): it holds the claim
        // through its ~1.5s debounce and releases when startStream() actually
        // runs (or the debounce is cancelled/superseded). Releasing here
        // would reopen the cross-path collision window the guard exists to
        // close (beads_mobilemusic-t96.26).

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
    /// Re-attempt an automatic reconnect that was deferred because other audio
    /// (an active phone call, a nav prompt, another media app) owned the
    /// session.  Polls `isOtherAudioPlaying` once a second; fires the play as
    /// soon as that audio releases, or gives up after
    /// `deferredReconnectMaxAttempts` seconds (channel stays set for a manual
    /// resume).  Aborts if the user has since moved to a different channel.
    internal func scheduleDeferredReconnect(for channel: Channel, attempt: Int = 0) {
        // Claim the shared guard once, at the start of the poll chain — the
        // recursive re-schedule below (attempt + 1) already holds it.
        if attempt == 0 {
            guard claimReconnectGuard(path: "deferred-reconnect") else { return }
        }
        deferredReconnectWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.currentChannel?.id == channel.id else {
                self.log.log("Deferred reconnect aborted — channel changed from \"\(channel.name)\"", category: .player)
                self.releaseReconnectGuard()
                return
            }
            if AVAudioSession.sharedInstance().isOtherAudioPlaying {
                if attempt >= self.deferredReconnectMaxAttempts {
                    self.log.log("Deferred reconnect gave up for \"\(channel.name)\" — other audio still active after \(self.deferredReconnectMaxAttempts)s", category: .audioSession)
                    self.releaseReconnectGuard()
                    return
                }
                self.scheduleDeferredReconnect(for: channel, attempt: attempt + 1)
                return
            }
            self.log.log("Deferred reconnect firing for \"\(channel.name)\" — other audio released", category: .audioSession)
            // Ownership transfers into play(): it carries the claim through
            // its debounce and releases when startStream() runs (or the
            // debounce is cancelled/superseded) — do not release here, that
            // would reopen the collision window (beads_mobilemusic-t96.26).
            self.play(channel: channel, userInitiated: false)
        }
        deferredReconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }
    /// Probes the stream server with a HEAD request before retrying VLC.
    /// Keeps probing every 2s until the server responds or the total timeout
    /// (probeTimeout) elapses.  Only starts VLC once the server is reachable,
    /// avoiding wasted player tear-down/create cycles on a dead network.
    internal func probeAndRetryStream(for channel: Channel) {
        guard currentChannel?.id == channel.id else {
            releaseReconnectGuard()
            return
        }

        let elapsed = Date().timeIntervalSince(probeStartTime ?? Date())
        if elapsed > probeTimeout {
            log.log("Connection timeout (\(Int(probeTimeout))s) — unable to reach stream server, channel=\"\(channel.name)\"", category: .player)
            probeStartTime = nil
            vlcZeroByteRetryCount = 0
            lastProbeHTTPStatus = nil
            isBuffering = false
            error = "Unable to connect — check your network connection."
            releaseReconnectGuard()
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
            releaseReconnectGuard()
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
                guard let self, self.currentChannel?.id == channel.id else {
                    self?.releaseReconnectGuard()
                    return
                }
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
                        self.releaseReconnectGuard()
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
                        guard let self, self.currentChannel?.id == channel.id else {
                            self?.releaseReconnectGuard()
                            return
                        }
                        self.probeStartTime = nil
                        self.lastLoggedVLCState = nil
                        self.releaseReconnectGuard()
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
}
