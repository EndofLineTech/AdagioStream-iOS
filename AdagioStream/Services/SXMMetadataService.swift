import Combine
import Foundation

@MainActor
public final class SXMMetadataService: ObservableObject {
    public static let shared = SXMMetadataService()

    @Published public var currentTrack: SXMTrack?
    @Published public var isSXMChannel = false
    @Published public var feedTracks: [String: SXMTrack] = [:]  // app channel ID -> latest track

    private let log = DebugLogger.shared
    // channelID -> station identifier (xmplaylist deeplink, or stellartunerlog channel id)
    private var channelDeeplinkMap: [String: String] = [:]
    private var currentDeeplink: String?
    private var pollTimer: Timer?
    private var inFlightTask: Task<Void, Never>?
    // stellartunerlog data refreshes every 30s (poll_interval_seconds) — don't poll faster
    private var pollInterval: TimeInterval { source == .stellartunerlog ? 30 : 15 }
    private let backgroundPollInterval: TimeInterval = 45
    private var feedTimer: Timer?
    private var feedTask: Task<Void, Never>?
    private let feedPollInterval: TimeInterval = 30
    private var isInBackground = false

    /// Active metadata source, captured from UserDefaults; updated via sourceChanged().
    private var source = SXMMetadataSource.current
    /// Channels from the last matchChannels() call, retained so sourceChanged() can re-match.
    private var lastMatchedChannels: [Channel] = []
    private var lastSortPrefixes: [String] = []
    /// Channel currently being polled, retained so sourceChanged() can restart its poll.
    private var currentChannel: Channel?
    /// Set by sourceChanged(); consumed when the new matching table lands.
    private var pendingResumeChannel: Channel?

    /// Timestamped track history from API responses, sorted newest-first.
    private var trackHistory: [SXMTrack] = []
    private let maxHistoryAge: TimeInterval = 600  // 10 minutes

    /// When true, polls continue but currentTrack is driven by showTrack(at:) instead of live data.
    private var isDisplaySuspended = false

    private var session: URLSession {
        source == .stellartunerlog ? APISession.stellartunerlog : APISession.xmplaylist
    }

    private init() {}

    // MARK: - Channel Matching

    /// Build a lookup table mapping app channel IDs to source station identifiers.
    /// Call after channels are loaded from providers.
    public func matchChannels(_ channels: [Channel], sortPrefixes: [String] = ["Radio: ", "TV: "]) {
        stopFeedPolling()
        feedTracks = [:]
        channelDeeplinkMap = [:]
        pendingResumeChannel = nil
        lastMatchedChannels = channels
        lastSortPrefixes = sortPrefixes
        let sxmPattern = #"(?i)\b(siriusxm|sirius\s*xm|sxm|sirius|xm)\b"#
        let sxmChannels = channels.filter {
            $0.group.range(of: sxmPattern, options: .regularExpression) != nil
        }
        guard !sxmChannels.isEmpty else {
            log.log("No SiriusXM channels found in \(channels.count) total channels", category: .sxm)
            return
        }
        log.log("Found \(sxmChannels.count) SiriusXM channels, fetching station list...", category: .sxm)

        Task {
            guard let stations = await fetchStationList() else { return }
            buildMatchingTable(appChannels: sxmChannels, stations: stations, sortPrefixes: sortPrefixes)
        }
    }

    /// Station catalog entry used for name matching: display name + the
    /// identifier stored in channelDeeplinkMap (deeplink or channel id).
    typealias MatchableStation = (name: String, identifier: String)

    private func fetchStationList() async -> [MatchableStation]? {
        switch source {
        case .xmplaylist:
            guard let url = URL(string: "https://xmplaylist.com/api/station") else { return nil }
            do {
                let (data, _) = try await session.data(from: url)
                let response = try JSONDecoder().decode(SXMStationListResponse.self, from: data)
                log.log("Fetched \(response.results.count) stations from xmplaylist", category: .sxm)
                return response.results.map { ($0.name, $0.deeplink) }
            } catch {
                log.log("Failed to fetch station list: \(error.localizedDescription)", category: .sxm)
                return nil
            }
        case .stellartunerlog:
            guard let url = URL(string: "https://api.stellartunerlog.com/v1/channels") else { return nil }
            do {
                let (data, _) = try await session.data(from: url)
                let response = try JSONDecoder().decode(STLChannelListResponse.self, from: data)
                log.log("Fetched \(response.channels.count) channels from stellartunerlog", category: .sxm)
                return response.channels.values.map { ($0.name, $0.id) }
            } catch {
                log.log("Failed to fetch station list: \(error.localizedDescription)", category: .sxm)
                return nil
            }
        }
    }

    private func buildMatchingTable(appChannels: [Channel], stations: [MatchableStation], sortPrefixes: [String]) {
        // Build normalized station lookup
        let stationsByName = Dictionary(
            stations.map { ($0.name.lowercased().trimmingCharacters(in: .whitespaces), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var matched = 0
        var unmatched: [String] = []
        for channel in appChannels {
            var cleanName = channel.name
            var strippedPrefix: String?
            for prefix in sortPrefixes {
                if cleanName.hasPrefix(prefix) {
                    strippedPrefix = prefix
                    cleanName = String(cleanName.dropFirst(prefix.count))
                    break
                }
            }
            let normalized = cleanName.lowercased().trimmingCharacters(in: .whitespaces)

            if let strippedPrefix {
                log.log("MATCH: \"\(channel.name)\" → stripped \"\(strippedPrefix)\" → normalized \"\(normalized)\"", category: .sxm)
            }

            // Exact match first
            if let station = stationsByName[normalized] {
                channelDeeplinkMap[channel.id] = station.identifier
                matched += 1
                log.log("MATCH: \"\(channel.name)\" ✓ exact → \"\(station.name)\" (id=\(station.identifier))", category: .sxm)
                continue
            }

            // Word-boundary match: station name appears as whole word(s) in channel name or vice versa
            if let station = stations.first(where: {
                let stationNorm = $0.name.lowercased().trimmingCharacters(in: .whitespaces)
                let stationPattern = "\\b\(NSRegularExpression.escapedPattern(for: stationNorm))\\b"
                let channelPattern = "\\b\(NSRegularExpression.escapedPattern(for: normalized))\\b"
                return stationNorm.range(of: channelPattern, options: .regularExpression) != nil
                    || normalized.range(of: stationPattern, options: .regularExpression) != nil
            }) {
                channelDeeplinkMap[channel.id] = station.identifier
                matched += 1
                log.log("MATCH: \"\(channel.name)\" ✓ contains → \"\(station.name)\" (id=\(station.identifier))", category: .sxm)
            } else {
                unmatched.append(channel.name)
                log.log("MATCH: \"\(channel.name)\" ✗ no match (normalized=\"\(normalized)\")", category: .sxm)
            }
        }

        log.log("Matching complete: \(matched)/\(appChannels.count) matched, \(unmatched.count) unmatched", category: .sxm)
        if !unmatched.isEmpty {
            log.log("Unmatched channels: \(unmatched.joined(separator: ", "))", category: .sxm)
        }

        hasSXMChannels = true
        if feedWanted {
            startFeedPolling()
        }

        // Resume polling for the channel that was live before a source switch
        if let channel = pendingResumeChannel {
            pendingResumeChannel = nil
            channelChanged(to: channel)
        }
    }

    // MARK: - Source Switching

    /// Called when the user changes the metadata source in Settings.
    /// Re-runs matching against the new source and restarts any active poll.
    public func sourceChanged() {
        let newSource = SXMMetadataSource.current
        guard newSource != source else { return }
        source = newSource
        log.log("Metadata source changed to \(newSource.rawValue), re-matching channels", category: .sxm)
        let resumeChannel = currentChannel
        stopPolling()
        matchChannels(lastMatchedChannels, sortPrefixes: lastSortPrefixes)
        pendingResumeChannel = resumeChannel
    }

    // MARK: - Feed Polling

    /// Reverse lookup: deeplink -> [app channel IDs]
    private var deeplinkToChannelIDs: [String: [String]] {
        var map: [String: [String]] = [:]
        for (channelID, deeplink) in channelDeeplinkMap {
            map[deeplink, default: []].append(channelID)
        }
        return map
    }

    /// Whether the channel list UI is currently visible and wants feed updates.
    private var feedWanted = false
    private var hasSXMChannels = false
    private var lastFeedLogLine: String?

    /// Call when channel list becomes visible/hidden to start/stop feed polling.
    public func setFeedPollingEnabled(_ enabled: Bool) {
        feedWanted = enabled
        if enabled && hasSXMChannels && feedTimer == nil && !isInBackground {
            startFeedPolling()
        } else if !enabled {
            stopFeedPolling()
        }
    }

    /// Called when the app enters/leaves the background.
    public func setBackgroundMode(_ background: Bool) {
        isInBackground = background
        if background {
            // Stop feed polling entirely — no visible channel list
            stopFeedPolling()
            // Slow track polling for Lock Screen metadata
            restartTrackPollingIfActive(interval: backgroundPollInterval)
        } else {
            // Restore normal track poll rate
            restartTrackPollingIfActive(interval: pollInterval)
            // Resume feed if the channel list wants it
            if feedWanted && hasSXMChannels {
                startFeedPolling()
            }
        }
    }

    private func restartTrackPollingIfActive(interval: TimeInterval) {
        guard let deeplink = currentDeeplink else { return }
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.currentDeeplink == deeplink else { return }
                self.fetchCurrentTrack(deeplink: deeplink)
            }
        }
    }

    private func startFeedPolling() {
        stopFeedPolling()
        log.log("Starting feed polling (interval=\(feedPollInterval)s)", category: .sxm)
        fetchFeed()
        feedTimer = Timer.scheduledTimer(withTimeInterval: feedPollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.fetchFeed()
            }
        }
    }

    private func stopFeedPolling() {
        feedTimer?.invalidate()
        feedTimer = nil
        feedTask?.cancel()
        feedTask = nil
    }

    private func fetchFeed() {
        feedTask?.cancel()
        feedTask = Task {
            switch source {
            case .xmplaylist: await fetchXMPlaylistFeed()
            case .stellartunerlog: await fetchStellarTunerLogFeed()
            }
        }
    }

    private func fetchXMPlaylistFeed() async {
        guard let url = URL(string: "https://xmplaylist.com/api/feed") else { return }
        do {
            let (data, _) = try await session.data(from: url)
            guard !Task.isCancelled else { return }
            let response = try JSONDecoder().decode(SXMFeedResponse.self, from: data)

            let lookup = deeplinkToChannelIDs

            // Group by channelId (deeplink), pick newest per channel
            var newestByDeeplink: [String: SXMFeedEntry] = [:]
            for entry in response.results {
                if let existing = newestByDeeplink[entry.channelId] {
                    let existingDate = existing.timestamp.flatMap { SXMTrackEntry.iso8601.date(from: $0) } ?? .distantPast
                    let newDate = entry.timestamp.flatMap { SXMTrackEntry.iso8601.date(from: $0) } ?? .distantPast
                    if newDate > existingDate {
                        newestByDeeplink[entry.channelId] = entry
                    }
                } else {
                    newestByDeeplink[entry.channelId] = entry
                }
            }

            // Map deeplinks to app channel IDs
            var newFeedTracks: [String: SXMTrack] = [:]
            for (deeplink, entry) in newestByDeeplink {
                guard let channelIDs = lookup[deeplink] else { continue }
                let track = entry.toSXMTrack()
                for id in channelIDs {
                    newFeedTracks[id] = track
                }
            }

            if feedTracks != newFeedTracks { feedTracks = newFeedTracks }
            let feedLogLine = "Feed updated: \(newFeedTracks.count) channels with tracks (from \(response.results.count) entries)"
            if feedLogLine != lastFeedLogLine {
                lastFeedLogLine = feedLogLine
                log.log(feedLogLine, category: .sxm)
            }
        } catch {
            guard !Task.isCancelled else { return }
            log.log("Feed fetch failed: \(error.localizedDescription)", category: .sxm)
        }
    }

    private func fetchStellarTunerLogFeed() async {
        guard let url = URL(string: "https://api.stellartunerlog.com/v1/nowplaying") else { return }
        do {
            let (data, _) = try await session.data(from: url)
            guard !Task.isCancelled else { return }
            let response = try JSONDecoder().decode(STLNowPlayingResponse.self, from: data)

            let lookup = deeplinkToChannelIDs
            var newFeedTracks: [String: SXMTrack] = [:]
            for (stationID, station) in response.stations {
                guard let channelIDs = lookup[stationID],
                      let track = station.toSXMTrack(startedAt: nil) else { continue }
                for id in channelIDs {
                    newFeedTracks[id] = track
                }
            }

            if feedTracks != newFeedTracks { feedTracks = newFeedTracks }
            let feedLogLine = "Feed updated: \(newFeedTracks.count) channels with tracks (from \(response.stations.count) stations)"
            if feedLogLine != lastFeedLogLine {
                lastFeedLogLine = feedLogLine
                log.log(feedLogLine, category: .sxm)
            }
        } catch {
            guard !Task.isCancelled else { return }
            log.log("Feed fetch failed: \(error.localizedDescription)", category: .sxm)
        }
    }

    // MARK: - Polling

    public func channelChanged(to channel: Channel) {
        // Coming back to live — clear suspension and reset
        isDisplaySuspended = false
        stopPolling()

        guard let deeplink = channelDeeplinkMap[channel.id] else {
            isSXMChannel = false
            currentTrack = nil
            return
        }

        isSXMChannel = true
        currentDeeplink = deeplink
        currentChannel = channel
        log.log("SXM channel active: \"\(channel.name)\" → deeplink=\"\(deeplink)\"", category: .sxm)

        // Immediate first fetch
        fetchCurrentTrack(deeplink: deeplink)

        // Start polling timer
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.currentDeeplink == deeplink else { return }
                self.fetchCurrentTrack(deeplink: deeplink)
            }
        }
    }

    /// Full stop — clears everything including history. Use for explicit user stop/pause.
    public func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        inFlightTask?.cancel()
        inFlightTask = nil
        currentDeeplink = nil
        currentChannel = nil
        currentTrack = nil
        isSXMChannel = false
        isDisplaySuspended = false
        trackHistory = []
    }

    /// Suspend display updates but keep polling and history.
    /// Used during audio interruptions so track data stays current.
    public func suspendForTimeShift() {
        isDisplaySuspended = true
        log.log("Display suspended for time-shift, polling continues (history: \(trackHistory.count) tracks)", category: .sxm)
    }

    /// Look up and display the track that was playing at the given date.
    /// Call from syncState() during buffer playback.
    public func showTrack(at date: Date) {
        guard isDisplaySuspended else { return }
        let track = self.track(at: date)
        if currentTrack?.id != track?.id {
            if let track {
                log.log("Time-shift track: \"\(track.title)\" by \(track.artistDisplay) (started \(track.startedAt?.description ?? "?"))", category: .sxm)
            } else {
                log.log("Time-shift: no track for \(date)", category: .sxm)
            }
            currentTrack = track
        }
    }

    /// Find the track that was playing at the given date.
    /// Returns the most recent track whose startedAt <= date.
    public func track(at date: Date) -> SXMTrack? {
        // trackHistory is sorted newest-first
        trackHistory.first(where: { ($0.startedAt ?? .distantPast) <= date })
    }

    private func fetchCurrentTrack(deeplink: String) {
        inFlightTask?.cancel()
        inFlightTask = Task {
            switch source {
            case .xmplaylist: await fetchXMPlaylistTrack(deeplink: deeplink)
            case .stellartunerlog: await fetchStellarTunerLogTrack(channelID: deeplink)
            }
        }
    }

    private func fetchXMPlaylistTrack(deeplink: String) async {
        guard let encoded = deeplink.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://xmplaylist.com/api/station/\(encoded)") else { return }
        do {
            let (data, _) = try await session.data(from: url)
            guard !Task.isCancelled else { return }
            let response = try JSONDecoder().decode(SXMStationTracksResponse.self, from: data)

            // Update history from all tracks in the response
            let tracks = response.results.map { $0.toSXMTrack() }
            mergeIntoHistory(tracks)

            // Only update live display if not suspended for time-shift
            guard !isDisplaySuspended else { return }

            if let latest = tracks.first {
                if currentTrack?.id != latest.id {
                    log.log("Now playing: \"\(latest.title)\" by \(latest.artistDisplay)", category: .sxm)
                    currentTrack = latest
                }
            } else {
                if currentTrack != nil {
                    log.log("Track cleared (commercial break?)", category: .sxm)
                    currentTrack = nil
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            log.log("Track fetch failed: \(error.localizedDescription)", category: .sxm)
        }
    }

    private func fetchStellarTunerLogTrack(channelID: String) async {
        guard let encoded = channelID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.stellartunerlog.com/v1/nowplaying/\(encoded)") else { return }
        do {
            let (data, _) = try await session.data(from: url)
            guard !Task.isCancelled else { return }
            let response = try JSONDecoder().decode(STLStationResponse.self, from: data)

            // No per-track timestamp from this API: stamp first observation,
            // reusing the startedAt already in history for the same track id.
            let track = Self.stlTrack(from: response.station, history: trackHistory)
            if let track {
                mergeIntoHistory([track])
            }

            // Only update live display if not suspended for time-shift
            guard !isDisplaySuspended else { return }

            if let track {
                if currentTrack?.id != track.id {
                    log.log("Now playing: \"\(track.title)\" by \(track.artistDisplay)", category: .sxm)
                    currentTrack = track
                }
            } else {
                if currentTrack != nil {
                    log.log("Track cleared (non-music cut: \(response.station.cutType))", category: .sxm)
                    currentTrack = nil
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            log.log("Track fetch failed: \(error.localizedDescription)", category: .sxm)
        }
    }

    /// Build an SXMTrack from a stellartunerlog station snapshot.
    /// Returns nil for non-music cuts. startedAt is the first time we observed
    /// this (station, artist, title) — reused from history when already seen.
    nonisolated static func stlTrack(from station: STLStation, history: [SXMTrack], now: Date = Date()) -> SXMTrack? {
        let startedAt = history.first(where: { $0.id == station.trackID })?.startedAt ?? now
        return station.toSXMTrack(startedAt: startedAt)
    }

    private func mergeIntoHistory(_ tracks: [SXMTrack]) {
        let existingIDs = Set(trackHistory.map(\.id))
        let newTracks = tracks.filter { !existingIDs.contains($0.id) }
        trackHistory.append(contentsOf: newTracks)

        // Sort newest-first by startedAt
        trackHistory.sort { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }

        // Prune entries older than maxHistoryAge
        let cutoff = Date().addingTimeInterval(-maxHistoryAge)
        trackHistory.removeAll { ($0.startedAt ?? .distantPast) < cutoff }
    }
}
