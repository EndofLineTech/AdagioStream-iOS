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
    // Getter internal for tests (beads_mobilemusic-t3s); setter stays private.
    private(set) var channelDeeplinkMap: [String: String] = [:]
    private var mappedChannelIdentities: [String: ChannelIdentity] = [:]
    private var eligibleChannelIdentities: [String: ChannelIdentity] = [:]
    private var currentDeeplink: String?
    private var pollTimer: Timer?
    var trackTask: Task<Void, Never>?
    // User-chosen foreground per-channel poll interval (clamped 10...45s, default 30s),
    // shared across both sources. Read live so a change applies on the next tick.
    private var pollInterval: TimeInterval { SXMPollInterval.current }
    private let backgroundPollInterval: TimeInterval = 45
    private var feedTimer: Timer?
    var feedTask: Task<Void, Never>?
    private let feedPollInterval: TimeInterval = 30
    private var isInBackground = false

    /// Active metadata source, captured from UserDefaults; updated via sourceChanged().
    private var source = SXMMetadataSource.current
    /// Channels from the last matchChannels() call, retained so sourceChanged() can re-match.
    private var lastMatchedChannels: [Channel] = []
    private var lastSelectedGroupNames: Set<String> = []
    private var lastSortPrefixes: [String] = []
    /// Channel currently playing (mapped or not), retained so sourceChanged()
    /// and a late station-list success can (re)start its poll.
    private var currentChannel: Channel?
    /// Set by sourceChanged(); consumed when the new matching table lands.
    private var pendingResumeChannel: Channel?
    /// Bumped by every matchChannels() call; the station-list retry loop exits
    /// when its captured generation is superseded (beads_mobilemusic-k7m).
    private var matchGeneration = 0

    /// Timestamped track history from API responses, sorted newest-first.
    private var trackHistory: [SXMTrack] = []
    private let maxHistoryAge: TimeInterval = 600  // 10 minutes

    /// When true, polls continue but currentTrack is driven by showTrack(at:) instead of live data.
    private var isDisplaySuspended = false

    private func session(for source: SXMMetadataSource) -> URLSession {
        source == .stellartunerlog ? APISession.stellartunerlog : APISession.xmplaylist
    }

    /// Internal (not private) so tests can build fresh instances instead of
    /// sharing singleton state; production uses `shared` (beads_mobilemusic-t3s).
    init() {}

    // MARK: - Test Seams (beads_mobilemusic-t3s)

    /// When set, consulted instead of the real network fetch in the retry loop.
    var stationListFetcher: (@MainActor () async -> [MatchableStation]?)?
    /// Optional identifier-keyed fetch seams for deterministic lifecycle tests.
    var feedFetcher: (@MainActor () async -> [String: SXMTrack]?)?
    var trackFetcher: (@MainActor (String) async -> [SXMTrack]?)?
    /// Backoff sleep for the retry loop. Returns true when the sleep was
    /// cancelled — the loop must exit instead of hot-looping with zero delay.
    var retrySleep: @MainActor (TimeInterval) async -> Bool = { delay in
        (try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))) == nil
    }
    /// Retained so tests can await loop completion. Superseded work is cancelled
    /// and still guarded by generation because not every async source cooperates
    /// with cancellation.
    var matchTask: Task<Void, Never>?

    private struct ChannelIdentity: Hashable {
        let id: String
        let name: String
        let streamURL: URL
        let group: String
        let providerName: String?
        let isCustomPlaylist: Bool

        init(_ channel: Channel) {
            id = channel.id
            name = channel.name
            streamURL = channel.streamURL
            group = channel.group
            providerName = channel.providerName
            isCustomPlaylist = channel.isCustomPlaylist
        }
    }

    // MARK: - Channel Matching

    /// Build a lookup table mapping app channel IDs to source station identifiers.
    /// Call after channels are loaded from providers.
    public func matchChannels(
        _ channels: [Channel],
        selectedGroupNames: Set<String>,
        sortPrefixes: [String] = ["Radio: ", "TV: "]
    ) {
        matchGeneration += 1
        let generation = matchGeneration
        let matchSource = source
        matchTask?.cancel()
        matchTask = nil
        stopFeedPolling()
        pendingResumeChannel = nil
        lastMatchedChannels = channels
        lastSelectedGroupNames = selectedGroupNames
        lastSortPrefixes = sortPrefixes
        let sxmChannels = channels.filter { selectedGroupNames.contains($0.group) }
        let newEligibleIdentities = Dictionary(
            sxmChannels.map { ($0.id, ChannelIdentity($0)) },
            uniquingKeysWith: { first, _ in first }
        )

        let oldMap = channelDeeplinkMap
        channelDeeplinkMap = channelDeeplinkMap.filter { id, _ in
            mappedChannelIdentities[id] == newEligibleIdentities[id]
        }
        mappedChannelIdentities = mappedChannelIdentities.filter { id, identity in
            newEligibleIdentities[id] == identity && channelDeeplinkMap[id] != nil
        }
        feedTracks = feedTracks.filter { id, _ in
            channelDeeplinkMap[id] != nil && channelDeeplinkMap[id] == oldMap[id]
        }
        eligibleChannelIdentities = newEligibleIdentities

        if let channel = currentChannel,
           newEligibleIdentities[channel.id] != ChannelIdentity(channel) {
            stopPollingForEligibilityChange()
        } else if let channel = currentChannel,
                  let activeDeeplink = currentDeeplink,
                  channelDeeplinkMap[channel.id] != activeDeeplink {
            channelChanged(to: channel)
        } else if let deeplink = currentDeeplink {
            // Any request from the previous selection generation is stale, even
            // when this channel remains eligible. Keep displayed metadata and
            // replace only the request.
            fetchCurrentTrack(deeplink: deeplink)
        }

        guard !sxmChannels.isEmpty else {
            channelDeeplinkMap = [:]
            mappedChannelIdentities = [:]
            eligibleChannelIdentities = [:]
            feedTracks = [:]
            hasSXMChannels = false
            if currentChannel != nil || currentDeeplink != nil || currentTrack != nil || isSXMChannel {
                stopPollingForEligibilityChange()
            }
            log.log("No channels found in selected SiriusXM groups", category: .sxm)
            return
        }
        hasSXMChannels = !channelDeeplinkMap.isEmpty
        if feedWanted && hasSXMChannels && !isInBackground {
            startFeedPolling()
        }
        log.log("Found \(sxmChannels.count) channels in selected SiriusXM groups, fetching station list...", category: .sxm)

        matchTask = Task {
            // Retry until the list loads or a newer matchChannels() supersedes
            // this loop — a single failed fetch at launch must not disable SXM
            // metadata for the whole session (beads_mobilemusic-k7m).
            var delay: TimeInterval = 5
            while true {
                let stations: [MatchableStation]?
                if let fetcher = stationListFetcher {
                    stations = await fetcher()
                } else {
                    stations = await fetchStationList(source: matchSource)
                }
                guard isMatchCurrent(
                    generation: generation,
                    source: matchSource,
                    eligibleIdentities: newEligibleIdentities
                ) else { return }
                if let stations {
                    publishMatchingTable(
                        appChannels: sxmChannels,
                        eligibleIdentities: newEligibleIdentities,
                        stations: stations,
                        sortPrefixes: sortPrefixes,
                        generation: generation,
                        source: matchSource
                    )
                    return
                }
                // First failure only (pendingResumeChannel is consumed): don't
                // leave the UI hanging on a source switch — drop SXM metadata
                // for the pending channel now; the loop keeps retrying.
                if let channel = pendingResumeChannel {
                    pendingResumeChannel = nil
                    log.log("Station list fetch failed during source switch; dropping SXM metadata for \"\(channel.name)\"", category: .sxm)
                    channelChanged(to: channel)
                }
                log.log("Station list fetch failed; retrying in \(Int(delay))s", category: .sxm)
                // Cancelled sleep = exit; otherwise a cancelled Task would spin
                // a zero-delay hot retry loop (beads_mobilemusic-t3s).
                if await retrySleep(delay) { return }
                guard isMatchCurrent(
                    generation: generation,
                    source: matchSource,
                    eligibleIdentities: newEligibleIdentities
                ) else { return }
                delay = min(delay * 2, 60)
            }
        }
    }

    /// Station catalog entry used for name matching: display name + the
    /// identifier stored in channelDeeplinkMap (deeplink or channel id).
    typealias MatchableStation = (name: String, identifier: String)

    private func fetchStationList(source: SXMMetadataSource) async -> [MatchableStation]? {
        switch source {
        case .xmplaylist:
            guard let url = URL(string: "https://xmplaylist.com/api/station") else { return nil }
            do {
                let (data, _) = try await session(for: source).data(from: url)
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
                let (data, _) = try await session(for: source).data(from: url)
                let response = try JSONDecoder().decode(STLChannelListResponse.self, from: data)
                log.log("Fetched \(response.channels.count) channels from stellartunerlog", category: .sxm)
                // Dictionary iteration order is nondeterministic — sort so
                // word-boundary matching always picks the same station.
                return response.channels.values.sorted { $0.id < $1.id }.map { ($0.name, $0.id) }
            } catch {
                log.log("Failed to fetch station list: \(error.localizedDescription)", category: .sxm)
                return nil
            }
        }
    }

    private func publishMatchingTable(
        appChannels: [Channel],
        eligibleIdentities: [String: ChannelIdentity],
        stations: [MatchableStation],
        sortPrefixes: [String],
        generation: Int,
        source: SXMMetadataSource
    ) {
        let newMap = Self.buildDeeplinkMap(
            appChannels: appChannels, stations: stations, sortPrefixes: sortPrefixes)
        guard isMatchCurrent(
            generation: generation,
            source: source,
            eligibleIdentities: eligibleIdentities
        ) else { return }

        let oldMap = channelDeeplinkMap
        let oldIdentities = mappedChannelIdentities
        channelDeeplinkMap = newMap
        mappedChannelIdentities = eligibleIdentities.filter { newMap[$0.key] != nil }
        feedTracks = feedTracks.filter { id, _ in
            newMap[id] == oldMap[id] && eligibleIdentities[id] == oldIdentities[id]
        }

        hasSXMChannels = !newMap.isEmpty
        if feedWanted {
            if hasSXMChannels && !isInBackground {
                startFeedPolling()
            } else {
                stopFeedPolling()
            }
        }

        // Resume polling for the channel that was live before a source switch
        if let channel = pendingResumeChannel {
            pendingResumeChannel = nil
            channelChanged(to: channel)
        } else if let channel = currentChannel,
                  currentDeeplink != channelDeeplinkMap[channel.id] {
            channelChanged(to: channel)
        }
    }

    private func isMatchCurrent(
        generation: Int,
        source: SXMMetadataSource,
        eligibleIdentities: [String: ChannelIdentity]
    ) -> Bool {
        !Task.isCancelled
            && generation == matchGeneration
            && source == self.source
            && eligibleIdentities == self.eligibleChannelIdentities
    }

    /// Pure matching core (internal for tests): app channel ID -> station identifier.
    nonisolated static func buildDeeplinkMap(appChannels: [Channel], stations: [MatchableStation], sortPrefixes: [String]) -> [String: String] {
        let log = DebugLogger.shared
        // Build normalized station lookup
        let stationsByName = Dictionary(
            stations.map { ($0.name.lowercased().trimmingCharacters(in: .whitespaces), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var map: [String: String] = [:]
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
                map[channel.id] = station.identifier
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
                map[channel.id] = station.identifier
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
        return map
    }

    // MARK: - Source Switching

    /// Called when the user changes the metadata source in Settings.
    /// Re-runs matching against the new source and restarts any active poll.
    public func sourceChanged() {
        let newSource = SXMMetadataSource.current
        guard newSource != source else { return }
        source = newSource
        log.log("Metadata source changed to \(newSource.rawValue), re-matching channels", category: .sxm)
        // Fall back to pendingResumeChannel so a second toggle before the first
        // re-match lands doesn't drop the channel to resume.
        let resumeChannel = currentChannel ?? pendingResumeChannel
        // ponytail: switching sources during time-shift intentionally drops
        // track history and returns the display to live.
        stopPolling()
        // Old-source identifiers mean nothing to the new source; clear now so a
        // failed re-match leaves lookups missing (non-SXM) rather than mixed.
        channelDeeplinkMap = [:]
        mappedChannelIdentities = [:]
        eligibleChannelIdentities = [:]
        feedTracks = [:]
        hasSXMChannels = false
        matchChannels(
            lastMatchedChannels,
            selectedGroupNames: lastSelectedGroupNames,
            sortPrefixes: lastSortPrefixes
        )
        if let resumeChannel, lastSelectedGroupNames.contains(resumeChannel.group) {
            pendingResumeChannel = resumeChannel
        }
    }

    /// Apply a changed foreground poll interval immediately by restarting the
    /// active per-channel poll timer. No-op in background (that uses its own
    /// fixed backgroundPollInterval) or when nothing is being polled.
    public func pollIntervalChanged() {
        guard !isInBackground else { return }
        restartTrackPollingIfActive(interval: pollInterval)
    }

    // MARK: - Feed Polling

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
        let generation = matchGeneration
        let feedSource = source
        let mapping = channelDeeplinkMap
        let identities = mappedChannelIdentities
        guard !mapping.isEmpty else {
            feedTask = nil
            return
        }
        feedTask = Task {
            let snapshot: (tracks: [String: SXMTrack], sourceCount: Int)?
            if let feedFetcher {
                snapshot = await feedFetcher().map { ($0, $0.count) }
            } else {
                switch feedSource {
                case .xmplaylist:
                    snapshot = await fetchXMPlaylistFeed(source: feedSource)
                case .stellartunerlog:
                    snapshot = await fetchStellarTunerLogFeed(source: feedSource)
                }
            }
            guard let snapshot,
                  isFeedCurrent(
                    generation: generation,
                    source: feedSource,
                    mapping: mapping,
                    identities: identities
                  ) else { return }

            var newFeedTracks: [String: SXMTrack] = [:]
            for (channelID, identifier) in mapping {
                if let track = snapshot.tracks[identifier] {
                    newFeedTracks[channelID] = track
                }
            }
            if feedTracks != newFeedTracks { feedTracks = newFeedTracks }
            let feedLogLine = "Feed updated: \(newFeedTracks.count) channels with tracks (from \(snapshot.sourceCount) entries)"
            if feedLogLine != lastFeedLogLine {
                lastFeedLogLine = feedLogLine
                log.log(feedLogLine, category: .sxm)
            }
        }
    }

    private func isFeedCurrent(
        generation: Int,
        source: SXMMetadataSource,
        mapping: [String: String],
        identities: [String: ChannelIdentity]
    ) -> Bool {
        !Task.isCancelled
            && generation == matchGeneration
            && source == self.source
            && mapping == channelDeeplinkMap
            && identities == mappedChannelIdentities
    }

    private func fetchXMPlaylistFeed(
        source: SXMMetadataSource
    ) async -> (tracks: [String: SXMTrack], sourceCount: Int)? {
        guard let url = URL(string: "https://xmplaylist.com/api/feed") else { return nil }
        do {
            let (data, _) = try await session(for: source).data(from: url)
            guard !Task.isCancelled else { return nil }
            let response = try JSONDecoder().decode(SXMFeedResponse.self, from: data)

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

            return (
                newestByDeeplink.mapValues { $0.toSXMTrack() },
                response.results.count
            )
        } catch {
            guard !Task.isCancelled else { return nil }
            log.log("Feed fetch failed: \(error.localizedDescription)", category: .sxm)
            return nil
        }
    }

    private func fetchStellarTunerLogFeed(
        source: SXMMetadataSource
    ) async -> (tracks: [String: SXMTrack], sourceCount: Int)? {
        guard let url = URL(string: "https://api.stellartunerlog.com/v1/nowplaying") else { return nil }
        do {
            let (data, _) = try await session(for: source).data(from: url)
            guard !Task.isCancelled else { return nil }
            let response = try JSONDecoder().decode(STLNowPlayingResponse.self, from: data)

            var tracks: [String: SXMTrack] = [:]
            for (stationID, station) in response.stations {
                guard let track = station.toSXMTrack(startedAt: nil) else { continue }
                tracks[stationID] = track
            }
            return (tracks, response.stations.count)
        } catch {
            guard !Task.isCancelled else { return nil }
            log.log("Feed fetch failed: \(error.localizedDescription)", category: .sxm)
            return nil
        }
    }

    // MARK: - Polling

    public func channelChanged(to channel: Channel) {
        // Coming back to live — clear suspension and reset
        isDisplaySuspended = false
        stopPolling()
        // Remember the channel even when no mapping exists yet (stopPolling
        // nils this) — a late station-list success resumes metadata for it.
        currentChannel = channel

        guard let deeplink = channelDeeplinkMap[channel.id] else {
            isSXMChannel = false
            currentTrack = nil
            return
        }

        isSXMChannel = true
        currentDeeplink = deeplink
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
        clearTrackPolling(retainCurrentChannel: false)
    }

    /// Eligibility changes clear metadata immediately but playback may continue.
    /// Retaining the channel lets a later rematch resume polling without another
    /// audio-player channel-change callback.
    private func stopPollingForEligibilityChange() {
        clearTrackPolling(retainCurrentChannel: true)
    }

    private func clearTrackPolling(retainCurrentChannel: Bool) {
        let retainedChannel = retainCurrentChannel ? currentChannel : nil
        pollTimer?.invalidate()
        pollTimer = nil
        trackTask?.cancel()
        trackTask = nil
        currentDeeplink = nil
        currentChannel = retainedChannel
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
        trackTask?.cancel()
        guard let channel = currentChannel else {
            trackTask = nil
            return
        }
        let generation = matchGeneration
        let trackSource = source
        let identity = ChannelIdentity(channel)
        let history = trackHistory
        trackTask = Task {
            let tracks: [SXMTrack]?
            if let trackFetcher {
                tracks = await trackFetcher(deeplink)
            } else {
                tracks = await fetchTracks(
                    source: trackSource,
                    identifier: deeplink,
                    history: history
                )
            }
            guard let tracks,
                  isTrackCurrent(
                    generation: generation,
                    source: trackSource,
                    deeplink: deeplink,
                    identity: identity
                  ) else { return }

            mergeIntoHistory(tracks)
            guard !isDisplaySuspended else { return }
            if let latest = tracks.first {
                if currentTrack?.id != latest.id {
                    log.log("Now playing: \"\(latest.title)\" by \(latest.artistDisplay)", category: .sxm)
                    currentTrack = latest
                }
            } else if currentTrack != nil {
                log.log("Track cleared (commercial break?)", category: .sxm)
                currentTrack = nil
            }
        }
    }

    private func isTrackCurrent(
        generation: Int,
        source: SXMMetadataSource,
        deeplink: String,
        identity: ChannelIdentity
    ) -> Bool {
        !Task.isCancelled
            && generation == matchGeneration
            && source == self.source
            && currentDeeplink == deeplink
            && currentChannel.map(ChannelIdentity.init) == identity
            && eligibleChannelIdentities[identity.id] == identity
            && mappedChannelIdentities[identity.id] == identity
            && channelDeeplinkMap[identity.id] == deeplink
    }

    private func fetchTracks(
        source: SXMMetadataSource,
        identifier: String,
        history: [SXMTrack]
    ) async -> [SXMTrack]? {
        guard let encoded = identifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        let urlString: String
        switch source {
        case .xmplaylist:
            urlString = "https://xmplaylist.com/api/station/\(encoded)"
        case .stellartunerlog:
            urlString = "https://api.stellartunerlog.com/v1/nowplaying/\(encoded)"
        }
        guard let url = URL(string: urlString) else { return nil }

        do {
            let (data, _) = try await session(for: source).data(from: url)
            guard !Task.isCancelled else { return nil }
            switch source {
            case .xmplaylist:
                let response = try JSONDecoder().decode(SXMStationTracksResponse.self, from: data)
                return response.results.map { $0.toSXMTrack() }
            case .stellartunerlog:
                let response = try JSONDecoder().decode(STLStationResponse.self, from: data)
                return Self.stlTrack(from: response.station, history: history).map { [$0] } ?? []
            }
        } catch {
            guard !Task.isCancelled else { return nil }
            log.log("Track fetch failed: \(error.localizedDescription)", category: .sxm)
            return nil
        }
    }

    /// Build an SXMTrack from a stellartunerlog station snapshot.
    /// Returns nil for non-displayable cuts. startedAt is the first time we observed
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
