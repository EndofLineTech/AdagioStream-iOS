import Combine
import Foundation

@MainActor
final class ESPNScoreService: ObservableObject {
    static let shared = ESPNScoreService()

    /// Channel ID → matched game info, updated on each poll.
    @Published var gamesByChannel: [String: ESPNGameInfo] = [:]

    private let log = DebugLogger.shared
    private let session = PinnedURLSession.espn
    private let livePollInterval: TimeInterval = 15
    private let idlePollInterval: TimeInterval = 60

    private var pollTimer: Timer?
    private var pollTask: Task<Void, Never>?

    /// Channels we've matched to teams, keyed by team displayName (lowercased).
    private var teamToChannelIDs: [String: [String]] = [:]
    private var hasChannels = false
    private var pollingWanted = false
    private var hasLiveGame = false

    private static let sportsLeagues: Set<String> = ["NFL", "MLB", "NBA", "NHL"]
    private static let channelPrefixes = ["Radio: ", "TV: "]

    private init() {}

    // MARK: - Channel Matching

    /// Call after channels are loaded. Extracts team names from sports channel names
    /// and builds a lookup table for matching ESPN events.
    func matchChannels(_ channels: [Channel]) {
        teamToChannelIDs = [:]
        gamesByChannel = [:]

        let sportsChannels = channels.filter { channel in
            let upperGroup = channel.group.uppercased()
            return Self.sportsLeagues.contains(where: { upperGroup.contains($0) })
        }

        guard !sportsChannels.isEmpty else {
            hasChannels = false
            log.log("No sports channels found for ESPN matching", category: .espn)
            return
        }

        for channel in sportsChannels {
            var teamName = channel.name
            for prefix in Self.channelPrefixes {
                if teamName.hasPrefix(prefix) {
                    teamName = String(teamName.dropFirst(prefix.count))
                    break
                }
            }
            let normalized = teamName.lowercased().trimmingCharacters(in: .whitespaces)
            teamToChannelIDs[normalized, default: []].append(channel.id)
        }

        hasChannels = true
        log.log("Matched \(teamToChannelIDs.count) team names from \(sportsChannels.count) sports channels", category: .espn)

        if pollingWanted {
            startPolling()
        }
    }

    // MARK: - Polling Control

    func setPollingEnabled(_ enabled: Bool) {
        pollingWanted = enabled
        if enabled && hasChannels && pollTimer == nil {
            startPolling()
        } else if !enabled {
            stopPolling()
        }
    }

    private var currentPollInterval: TimeInterval {
        hasLiveGame ? livePollInterval : idlePollInterval
    }

    private func startPolling() {
        stopPolling()
        let interval = currentPollInterval
        log.log("Starting ESPN score polling (interval=\(interval)s, live=\(hasLiveGame))", category: .espn)
        fetchScoreboard()
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.fetchScoreboard()
            }
        }
    }

    private func adjustPollRateIfNeeded() {
        let wasLive = hasLiveGame
        hasLiveGame = gamesByChannel.values.contains(where: { $0.state == .live })
        if hasLiveGame != wasLive, pollingWanted {
            log.log("ESPN poll rate changed: live=\(hasLiveGame), interval=\(currentPollInterval)s", category: .espn)
            startPolling()  // restart timer with new interval
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Fetch & Match

    private func fetchScoreboard() {
        pollTask?.cancel()
        pollTask = Task {
            // For now, MLB only
            guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/baseball/mlb/scoreboard") else { return }
            do {
                let (data, _) = try await session.data(from: url)
                guard !Task.isCancelled else { return }
                let response = try JSONDecoder().decode(ESPNScoreboardResponse.self, from: data)
                matchEvents(response.events)
                adjustPollRateIfNeeded()
                log.log("ESPN scoreboard: \(response.events.count) events, \(gamesByChannel.count) matched to channels", category: .espn)
            } catch {
                guard !Task.isCancelled else { return }
                log.log("ESPN fetch failed: \(error.localizedDescription)", category: .espn)
            }
        }
    }

    private func matchEvents(_ events: [ESPNEvent]) {
        var newGames: [String: ESPNGameInfo] = [:]

        for event in events {
            guard let comp = event.competition,
                  let home = comp.homeTeam,
                  let away = comp.awayTeam else { continue }

            let gameInfo = ESPNGameInfo(
                awayAbbr: away.team.abbreviation,
                homeAbbr: home.team.abbreviation,
                awayScore: away.score,
                homeScore: home.score,
                awayRecord: away.overallRecord,
                homeRecord: home.overallRecord,
                state: ESPNGameInfo.GameState(rawValue: comp.status.type.state) ?? .pre,
                statusDetail: comp.status.type.shortDetail,
                outs: comp.situation?.outs
            )

            // Match home team
            let homeKey = home.team.displayName.lowercased()
            if let channelIDs = teamToChannelIDs[homeKey] {
                for id in channelIDs { newGames[id] = gameInfo }
            }

            // Match away team
            let awayKey = away.team.displayName.lowercased()
            if let channelIDs = teamToChannelIDs[awayKey] {
                for id in channelIDs { newGames[id] = gameInfo }
            }
        }

        if gamesByChannel != newGames { gamesByChannel = newGames }
    }
}
