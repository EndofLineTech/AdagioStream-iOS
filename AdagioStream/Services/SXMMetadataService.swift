import Combine
import Foundation

@MainActor
final class SXMMetadataService: ObservableObject {
    static let shared = SXMMetadataService()

    @Published var currentTrack: SXMTrack?
    @Published var isSXMChannel = false

    private let log = DebugLogger.shared
    private var channelDeeplinkMap: [String: String] = [:]  // channelID -> deeplink
    private var currentDeeplink: String?
    private var pollTimer: Timer?
    private var inFlightTask: Task<Void, Never>?
    private let pollInterval: TimeInterval = 30

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
        let sxmChannels = channels.filter {
            $0.group.localizedCaseInsensitiveContains("siriusxm") ||
            $0.group.localizedCaseInsensitiveContains("sirius xm")
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
    }

    // MARK: - Polling

    func channelChanged(to channel: Channel) {
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

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        inFlightTask?.cancel()
        inFlightTask = nil
        currentDeeplink = nil
        currentTrack = nil
        isSXMChannel = false
    }

    private func fetchCurrentTrack(deeplink: String) {
        inFlightTask?.cancel()
        inFlightTask = Task {
            guard let url = URL(string: "https://xmplaylist.com/api/station/\(deeplink)") else { return }
            do {
                let (data, _) = try await session.data(from: url)
                guard !Task.isCancelled else { return }
                let response = try JSONDecoder().decode(SXMStationTracksResponse.self, from: data)

                if let latest = response.results.first {
                    let track = latest.toSXMTrack()
                    if currentTrack?.id != track.id {
                        log.log("Now playing: \"\(track.title)\" by \(track.artistDisplay)", category: .sxm)
                        currentTrack = track
                    }
                } else {
                    // Empty results = commercial break or no data
                    if currentTrack != nil {
                        log.log("Track cleared (commercial break?)", category: .sxm)
                        currentTrack = nil
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                log.log("Track fetch failed: \(error.localizedDescription)", category: .sxm)
                // Keep last known track on error
            }
        }
    }
}
