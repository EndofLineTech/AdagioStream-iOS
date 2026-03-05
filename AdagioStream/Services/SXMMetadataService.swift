import Combine
import Foundation

@MainActor
final class SXMMetadataService: ObservableObject {
    static let shared = SXMMetadataService()

    @Published var currentTrack: SXMTrack?
    @Published var isSXMChannel = false
    @Published var feedTracks: [String: SXMTrack] = [:]  // app channel ID -> latest track

    private let log = DebugLogger.shared
    private var channelDeeplinkMap: [String: String] = [:]  // channelID -> deeplink
    private var currentDeeplink: String?
    private var pollTimer: Timer?
    private var inFlightTask: Task<Void, Never>?
    private let pollInterval: TimeInterval = 5
    private var feedTimer: Timer?
    private var feedTask: Task<Void, Never>?
    private let feedPollInterval: TimeInterval = 30

    /// Timestamped track history from API responses, sorted newest-first.
    private var trackHistory: [SXMTrack] = []
    private let maxHistoryAge: TimeInterval = 600  // 10 minutes

    /// When true, polls continue but currentTrack is driven by showTrack(at:) instead of live data.
    private var isDisplaySuspended = false

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.httpAdditionalHeaders = ["User-Agent": "AdagioStream/1.0"]
        return URLSession(configuration: config)
    }()

    private init() {}

    // MARK: - Channel Matching

    /// Build a lookup table mapping app channel IDs to xmplaylist deeplinks.
    /// Call after channels are loaded from providers.
    func matchChannels(_ channels: [Channel], sortPrefixes: [String] = ["Radio: ", "TV: "]) {
        stopFeedPolling()
        feedTracks = [:]
        channelDeeplinkMap = [:]
        let sxmChannels = channels.filter {
            $0.group.localizedCaseInsensitiveContains("siriusxm") ||
            $0.group.localizedCaseInsensitiveContains("sirius xm") ||
            $0.group.localizedCaseInsensitiveContains("sxm")
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

    private func fetchStationList() async -> [SXMStation]? {
        guard let url = URL(string: "https://xmplaylist.com/api/station") else { return nil }
        do {
            let (data, _) = try await session.data(from: url)
            let response = try JSONDecoder().decode(SXMStationListResponse.self, from: data)
            log.log("Fetched \(response.results.count) stations from xmplaylist", category: .sxm)
            return response.results
        } catch {
            log.log("Failed to fetch station list: \(error.localizedDescription)", category: .sxm)
            return nil
        }
    }

    private func buildMatchingTable(appChannels: [Channel], stations: [SXMStation], sortPrefixes: [String]) {
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
                channelDeeplinkMap[channel.id] = station.deeplink
                matched += 1
                log.log("MATCH: \"\(channel.name)\" ✓ exact → \"\(station.name)\" (deeplink=\(station.deeplink))", category: .sxm)
                continue
            }

            // Contains match: station name contains channel name or vice versa
            if let station = stations.first(where: {
                let stationNorm = $0.name.lowercased().trimmingCharacters(in: .whitespaces)
                return stationNorm.contains(normalized) || normalized.contains(stationNorm)
            }) {
                channelDeeplinkMap[channel.id] = station.deeplink
                matched += 1
                log.log("MATCH: \"\(channel.name)\" ✓ contains → \"\(station.name)\" (deeplink=\(station.deeplink))", category: .sxm)
            } else {
                unmatched.append(channel.name)
                log.log("MATCH: \"\(channel.name)\" ✗ no match (normalized=\"\(normalized)\")", category: .sxm)
            }
        }

        log.log("Matching complete: \(matched)/\(appChannels.count) matched, \(unmatched.count) unmatched", category: .sxm)
        if !unmatched.isEmpty {
            log.log("Unmatched channels: \(unmatched.joined(separator: ", "))", category: .sxm)
        }

        startFeedPolling()
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

                feedTracks = newFeedTracks
                log.log("Feed updated: \(newFeedTracks.count) channels with tracks (from \(response.results.count) entries)", category: .sxm)
            } catch {
                guard !Task.isCancelled else { return }
                log.log("Feed fetch failed: \(error.localizedDescription)", category: .sxm)
            }
        }
    }

    // MARK: - Polling

    func channelChanged(to channel: Channel) {
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
    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        inFlightTask?.cancel()
        inFlightTask = nil
        currentDeeplink = nil
        currentTrack = nil
        isSXMChannel = false
        isDisplaySuspended = false
        trackHistory = []
    }

    /// Suspend display updates but keep polling and history.
    /// Used during audio interruptions so track data stays current.
    func suspendForTimeShift() {
        isDisplaySuspended = true
        log.log("Display suspended for time-shift, polling continues (history: \(trackHistory.count) tracks)", category: .sxm)
    }

    /// Look up and display the track that was playing at the given date.
    /// Call from syncState() during buffer playback.
    func showTrack(at date: Date) {
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
    func track(at date: Date) -> SXMTrack? {
        // trackHistory is sorted newest-first
        trackHistory.first(where: { ($0.startedAt ?? .distantPast) <= date })
    }

    private func fetchCurrentTrack(deeplink: String) {
        inFlightTask?.cancel()
        inFlightTask = Task {
            guard let url = URL(string: "https://xmplaylist.com/api/station/\(deeplink)") else { return }
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
