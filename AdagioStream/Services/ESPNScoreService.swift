import Combine
import Foundation

@MainActor
final class ESPNScoreService: ObservableObject {
    static let shared = ESPNScoreService()

    /// Channel ID → matched game info, updated on each poll.
    @Published var gamesByChannel: [String: ESPNGameInfo] = [:]

    private let log = DebugLogger.shared
    private let session = PinnedURLSession.espn
    private var livePollInterval: TimeInterval = 15
    private let idlePollInterval: TimeInterval = 60

    private var pollTimer: Timer?
    private var pollTask: Task<Void, Never>?

    /// Channels we've matched to teams, keyed by team displayName (lowercased).
    private var teamToChannelIDs: [String: [String]] = [:]
    /// Sports channels with EPG data that weren't matched by team name — EPG fallback candidates.
    private var epgCandidateChannels: [String: String] = [:]  // channelID → epgChannelID
    /// Pre-compiled search tokens per ESPN team displayName for EPG title matching.
    private var teamTokenCache: [String: TeamSearchTokens] = [:]
    private var hasChannels = false
    private var pollingWanted = false
    private var hasLiveGame = false
    private var lastScoreboardLogLine: String?

    private static let sportsLeagues: Set<String> = ["NFL", "MLB", "NBA", "NHL"]
    private static let channelPrefixes = ["Radio: ", "TV: "]
    private static let allLeagues: [ESPNLeague] = [.mlb, .nba, .nhl, .nfl]

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
        teamTokenCache = [:]

        // Build EPG candidate list: sports channels with EPG that didn't match a team name
        let matchedChannelIDs = Set(teamToChannelIDs.values.flatMap { $0 })
        epgCandidateChannels = [:]
        for channel in sportsChannels {
            guard let epgID = channel.epgChannelID, !epgID.isEmpty else { continue }
            guard !matchedChannelIDs.contains(channel.id) else { continue }
            epgCandidateChannels[channel.id] = epgID
        }

        log.log("Matched \(teamToChannelIDs.count) team names from \(sportsChannels.count) sports channels, \(epgCandidateChannels.count) EPG fallback candidates", category: .espn)

        if pollingWanted {
            startPolling()
        }
    }

    // MARK: - Polling Control

    func setLivePollInterval(_ interval: TimeInterval) {
        guard interval != livePollInterval else { return }
        livePollInterval = interval
        if pollingWanted, hasLiveGame {
            log.log("ESPN live poll interval changed to \(Int(interval))s", category: .espn)
            startPolling()
        }
    }

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
        fetchAllScoreboards()
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.fetchAllScoreboards()
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

    private func fetchAllScoreboards() {
        pollTask?.cancel()
        pollTask = Task {
            var allEvents: [(ESPNLeague, [ESPNEvent])] = []
            var fetchedLeagues: Set<ESPNLeague> = []

            await withTaskGroup(of: (ESPNLeague, Result<[ESPNEvent], Error>).self) { group in
                for league in Self.allLeagues {
                    group.addTask { [session] in
                        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(league.sportPath)/scoreboard") else {
                            return (league, .failure(URLError(.badURL)))
                        }
                        do {
                            let (data, _) = try await session.data(from: url)
                            let response = try JSONDecoder().decode(ESPNScoreboardResponse.self, from: data)
                            return (league, .success(response.events))
                        } catch {
                            return (league, .failure(error))
                        }
                    }
                }
                for await (league, result) in group {
                    switch result {
                    case .success(let events):
                        allEvents.append((league, events))
                    case .failure(let error):
                        self.log.log("ESPN \(league.rawValue.uppercased()) fetch failed: \(error.localizedDescription)", category: .espn)
                    }
                }
            }

            guard !Task.isCancelled else { return }

            // Only update data for leagues that responded successfully.
            // Keep existing entries for leagues that failed, so a transient
            // network blip on one league doesn't wipe live-game state and
            // cause poll-rate thrashing between 15s ↔ 60s.
            var newGames = gamesByChannel
            for (league, _) in allEvents { fetchedLeagues.insert(league) }
            // Clear entries for leagues that responded (will be re-populated below)
            for (channelID, info) in newGames where fetchedLeagues.contains(info.league) {
                newGames.removeValue(forKey: channelID)
            }
            var totalEvents = 0
            for (league, events) in allEvents {
                totalEvents += events.count
                matchEvents(events, league: league, into: &newGames)
            }

            // Second pass: EPG-based fallback for unmatched sports channels
            matchEventsViaEPG(allEvents, into: &newGames)

            if gamesByChannel != newGames {
                logGameChanges(old: gamesByChannel, new: newGames)
                gamesByChannel = newGames
            }
            adjustPollRateIfNeeded()
            let scoreLogLine = "ESPN scoreboard: \(totalEvents) events across \(allEvents.count) leagues, \(newGames.count) matched to channels"
            if scoreLogLine != lastScoreboardLogLine {
                lastScoreboardLogLine = scoreLogLine
                log.log(scoreLogLine, category: .espn)
            }
        }
    }

    private static let espnDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mmX"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func parseESPNDate(_ string: String) -> Date? {
        espnDateFormatter.date(from: string)
    }

    private func buildGameInfo(from event: ESPNEvent, league: ESPNLeague) -> ESPNGameInfo? {
        guard let comp = event.competition,
              let home = comp.homeTeam,
              let away = comp.awayTeam else { return nil }

        var possessionAbbr: String?
        if league == .nfl, let possID = comp.situation?.possession {
            if home.team.id == possID { possessionAbbr = home.team.abbreviation }
            else if away.team.id == possID { possessionAbbr = away.team.abbreviation }
        }

        return ESPNGameInfo(
            league: league,
            awayAbbr: away.team.abbreviation,
            homeAbbr: home.team.abbreviation,
            awayScore: away.score,
            homeScore: home.score,
            awayRecord: away.overallRecord,
            homeRecord: home.overallRecord,
            state: ESPNGameInfo.GameState(rawValue: comp.status.type.state) ?? .pre,
            statusDetail: comp.status.type.shortDetail,
            displayClock: comp.status.displayClock,
            period: comp.status.period,
            gameDate: Self.parseESPNDate(event.date),
            outs: comp.situation?.outs,
            balls: comp.situation?.balls,
            strikes: comp.situation?.strikes,
            onFirst: comp.situation?.onFirst,
            onSecond: comp.situation?.onSecond,
            onThird: comp.situation?.onThird,
            possessionTeamAbbr: possessionAbbr,
            downDistanceText: comp.situation?.shortDownDistanceText ?? comp.situation?.downDistanceText
        )
    }

    private func matchEvents(_ events: [ESPNEvent], league: ESPNLeague, into games: inout [String: ESPNGameInfo]) {
        for event in events {
            guard let gameInfo = buildGameInfo(from: event, league: league),
                  let comp = event.competition,
                  let home = comp.homeTeam,
                  let away = comp.awayTeam else { continue }

            let homeKey = home.team.displayName.lowercased()
            if let channelIDs = teamToChannelIDs[homeKey] {
                for id in channelIDs { games[id] = gameInfo }
            }

            let awayKey = away.team.displayName.lowercased()
            if let channelIDs = teamToChannelIDs[awayKey] {
                for id in channelIDs { games[id] = gameInfo }
            }
        }
    }

    // MARK: - EPG Fuzzy Matching

    private struct TeamSearchTokens {
        let fullName: String                        // "boston bruins"
        let nicknamePattern: NSRegularExpression    // \bbruins\b
        let abbrPattern: NSRegularExpression        // \bBOS\b
    }

    private func tokens(for team: ESPNTeam) -> TeamSearchTokens {
        if let cached = teamTokenCache[team.displayName] { return cached }
        let full = team.displayName.lowercased()
        let nickname = team.displayName.split(separator: " ").last.map(String.init) ?? team.displayName
        let result = TeamSearchTokens(
            fullName: full,
            nicknamePattern: try! NSRegularExpression(
                pattern: "\\b\(NSRegularExpression.escapedPattern(for: nickname))\\b",
                options: .caseInsensitive
            ),
            abbrPattern: try! NSRegularExpression(
                pattern: "\\b\(NSRegularExpression.escapedPattern(for: team.abbreviation))\\b",
                options: .caseInsensitive
            )
        )
        teamTokenCache[team.displayName] = result
        return result
    }

    private func epgTitleContainsTeam(_ title: String, tokens: TeamSearchTokens) -> Bool {
        let lowered = title.lowercased()
        // Tier 1: full display name (most precise)
        if lowered.contains(tokens.fullName) { return true }
        let range = NSRange(title.startIndex..., in: title)
        // Tier 2: team nickname with word boundary
        if tokens.nicknamePattern.firstMatch(in: title, range: range) != nil { return true }
        // Tier 3: abbreviation with word boundary
        if tokens.abbrPattern.firstMatch(in: title, range: range) != nil { return true }
        return false
    }

    private func matchEventsViaEPG(_ allEvents: [(ESPNLeague, [ESPNEvent])], into games: inout [String: ESPNGameInfo]) {
        guard !epgCandidateChannels.isEmpty else { return }

        let epgData = ProviderManager.shared.epgData
        var epgMatched = 0

        for (channelID, epgID) in epgCandidateChannels {
            guard games[channelID] == nil else { continue }
            guard let entries = epgData[epgID],
                  let currentEntry = entries.first(where: \.isCurrentlyAiring) else { continue }

            let title = currentEntry.title

            outer: for (league, events) in allEvents {
                for event in events {
                    guard let comp = event.competition,
                          let home = comp.homeTeam,
                          let away = comp.awayTeam,
                          let gameInfo = buildGameInfo(from: event, league: league) else { continue }

                    let homeTokens = tokens(for: home.team)
                    let awayTokens = tokens(for: away.team)

                    guard epgTitleContainsTeam(title, tokens: homeTokens),
                          epgTitleContainsTeam(title, tokens: awayTokens) else { continue }

                    games[channelID] = gameInfo
                    epgMatched += 1
                    break outer
                }
            }
        }

        if epgMatched > 0 {
            log.log("ESPN EPG fallback: matched \(epgMatched) channels via program titles", category: .espn)
        }
    }

    // MARK: - Change Logging

    /// Log per-game changes so we have visibility into score/inning updates.
    /// Only logs games we're actively displaying (matched to a channel).
    private func logGameChanges(old: [String: ESPNGameInfo], new: [String: ESPNGameInfo]) {
        // Deduplicate: multiple channel IDs can map to the same game.
        // Use the game key (away-home) to avoid duplicate log lines.
        var logged = Set<String>()
        for (channelID, newGame) in new {
            let gameKey = "\(newGame.awayAbbr)-\(newGame.homeAbbr)"
            guard !logged.contains(gameKey) else { continue }
            guard let oldGame = old[channelID] else {
                // New game appeared
                logged.insert(gameKey)
                log.log("ESPN game added: \(newGame.displayText)", category: .espn)
                continue
            }
            let scoreChanged = oldGame.awayScore != newGame.awayScore || oldGame.homeScore != newGame.homeScore
            let inningChanged = oldGame.statusDetail != newGame.statusDetail
            let stateChanged = oldGame.state != newGame.state
            if scoreChanged || inningChanged || stateChanged {
                logged.insert(gameKey)
                log.log("ESPN update: \(newGame.displayText)", category: .espn)
            }
        }
    }
}
