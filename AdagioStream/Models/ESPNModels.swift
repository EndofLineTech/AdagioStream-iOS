import Foundation

// MARK: - ESPN Scoreboard API Response

struct ESPNScoreboardResponse: Decodable {
    let events: [ESPNEvent]
}

struct ESPNEvent: Decodable, Identifiable {
    let id: String
    let date: String                   // ISO-8601 UTC, e.g. "2024-03-30T17:05Z"
    let shortName: String              // "MIN @ BOS"
    let competitions: [ESPNCompetition]

    var competition: ESPNCompetition? { competitions.first }
}

struct ESPNCompetition: Decodable {
    let competitors: [ESPNCompetitor]
    let status: ESPNStatus
    let situation: ESPNSituation?

    var homeTeam: ESPNCompetitor? { competitors.first(where: { $0.homeAway == "home" }) }
    var awayTeam: ESPNCompetitor? { competitors.first(where: { $0.homeAway == "away" }) }
}

struct ESPNSituation: Decodable {
    // MLB
    let outs: Int?
    let balls: Int?
    let strikes: Int?
    let onFirst: Bool?
    let onSecond: Bool?
    let onThird: Bool?
    // NFL
    let possession: String?            // team ID with possession
    let down: Int?
    let distance: Int?
    let yardLine: Int?
    let downDistanceText: String?      // "1st & 10 at GB 25"
    let shortDownDistanceText: String? // "1st & 10"
    let possessionText: String?        // "Green Bay Packers"
}

struct ESPNCompetitor: Decodable {
    let homeAway: String               // "home" or "away"
    let score: String                  // "0", "3", etc.
    let team: ESPNTeam
    let records: [ESPNRecord]?

    var overallRecord: String? {
        records?.first(where: { $0.name == "overall" })?.summary
    }
}

struct ESPNTeam: Decodable {
    let id: String
    let displayName: String            // "Boston Red Sox"
    let abbreviation: String           // "BOS"
}

struct ESPNRecord: Decodable {
    let name: String                   // "overall"
    let summary: String                // "9-11"
}

struct ESPNStatus: Decodable {
    let displayClock: String?          // "8:35", "0:00"
    let period: Int?                   // 1, 2, 3, 4
    let type: ESPNStatusType
}

struct ESPNStatusType: Decodable {
    let state: String                  // "pre", "in", "post"
    let shortDetail: String            // "3/15 - 1:05 PM EDT", "Bot 7th", "Final"
}

// MARK: - League

enum ESPNLeague: String, Equatable {
    case mlb
    case nba
    case nhl
    case nfl

    var sportPath: String {
        switch self {
        case .mlb: return "baseball/mlb"
        case .nba: return "basketball/nba"
        case .nhl: return "hockey/nhl"
        case .nfl: return "football/nfl"
        }
    }

    var periodName: String {
        switch self {
        case .mlb: return ""         // MLB uses innings, handled by shortDetail
        case .nba: return "Quarter"
        case .nhl: return "Period"
        case .nfl: return ""         // NFL uses custom format
        }
    }
}

// MARK: - Resolved Game Info for Display

/// A matched ESPN game ready for display in a channel row.
struct ESPNGameInfo: Equatable {
    let league: ESPNLeague
    let awayAbbr: String               // "MIN"
    let homeAbbr: String               // "BOS"
    let awayScore: String              // "3"
    let homeScore: String              // "0"
    let awayRecord: String?            // "7-13-1"
    let homeRecord: String?            // "9-11"
    let state: GameState               // .pre, .live, .post
    let statusDetail: String           // "Bot 7th", "8:35 - 1st", "Final"
    let displayClock: String?          // "8:35"
    let period: Int?                   // 1-4
    let gameDate: Date?                // Parsed UTC start time from ESPN
    // MLB
    let outs: Int?                     // 0-3 during live game
    let balls: Int?                    // 0-3 during live at-bat
    let strikes: Int?                  // 0-2 during live at-bat
    let onFirst: Bool?                 // Runner on 1B
    let onSecond: Bool?                // Runner on 2B
    let onThird: Bool?                 // Runner on 3B
    // NFL
    let possessionTeamAbbr: String?    // "GB" — team with the ball
    let downDistanceText: String?      // "1st & 10"

    enum GameState: String, Equatable {
        case pre
        case live = "in"
        case post
    }

    // MARK: - One-liner (channel row, mini player)

    var displayText: String {
        switch state {
        case .pre:
            return "\(awayAbbr)\(recordText(awayRecord)) @ \(homeAbbr)\(recordText(homeRecord)) · \(localStartTime)"
        case .live:
            return "\(scoreLine) · \(liveDetail)"
        case .post:
            return "\(scoreLine) · \(statusDetail)"
        }
    }

    // MARK: - Two-line (Now Playing, CarPlay)

    /// Line 1: score line
    var nowPlayingTitle: String {
        switch state {
        case .pre:
            return "\(awayAbbr)\(recordText(awayRecord)) @ \(homeAbbr)\(recordText(homeRecord))"
        case .live, .post:
            return scoreLine
        }
    }

    /// Line 2: game status
    var nowPlayingSubtitle: String {
        switch state {
        case .live:
            return liveDetail
        case .pre:
            return localStartTime
        case .post:
            return statusDetail
        }
    }

    // MARK: - Private Formatting

    private var scoreLine: String {
        switch league {
        case .nfl:
            // Football emoji next to team with possession
            let awayPoss = possessionTeamAbbr == awayAbbr ? "\u{1F3C8} " : ""
            let homePoss = possessionTeamAbbr == homeAbbr ? "\u{1F3C8} " : ""
            return "\(awayPoss)\(awayAbbr) \(awayScore) - \(homePoss)\(homeAbbr) \(homeScore)"
        default:
            return "\(awayAbbr) \(awayScore) - \(homeAbbr) \(homeScore)"
        }
    }

    private var liveDetail: String {
        switch league {
        case .mlb:
            return "\(statusDetail)\(countText)\(outsText)\(basesText)"
        case .nba, .nhl:
            let clock = displayClock ?? ""
            let periodStr = period.map { ordinal($0) + " " + league.periodName } ?? ""
            if clock.isEmpty { return periodStr }
            return "\(clock), \(periodStr)"
        case .nfl:
            var parts: [String] = []
            if let dd = downDistanceText { parts.append(dd) }
            if let p = period { parts.append("Q\(p)") }
            if let clock = displayClock, !clock.isEmpty { parts.append(clock) }
            return parts.joined(separator: ", ")
        }
    }

    private var countText: String {
        guard let balls, let strikes else { return "" }
        return ", \(balls)-\(strikes)"
    }

    private var outsText: String {
        guard let outs else { return "" }
        return ", \(outs) \(outs == 1 ? "Out" : "Outs")"
    }

    /// Diamond indicators for base runners: ◆ = occupied, ◇ = empty (3rd, 2nd, 1st)
    private var basesText: String {
        guard onFirst != nil || onSecond != nil || onThird != nil else { return "" }
        let first = (onFirst ?? false) ? "\u{25C6}" : "\u{25C7}"
        let second = (onSecond ?? false) ? "\u{25C6}" : "\u{25C7}"
        let third = (onThird ?? false) ? "\u{25C6}" : "\u{25C7}"
        return " \(third)\(second)\(first)"
    }

    /// Formats the game start time in the user's local timezone.
    /// Shows "Today, 1:05 PM" or "3/30, 1:05 PM" depending on the date.
    private var localStartTime: String {
        guard let date = gameDate else { return statusDetail }
        if Calendar.current.isDateInToday(date) {
            return "Today, \(Self.timeFormatter.string(from: date))"
        }
        return Self.dateTimeFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d, h:mm a"
        return f
    }()

    private func recordText(_ record: String?) -> String {
        record.map { " (\($0))" } ?? ""
    }

    private func ordinal(_ n: Int) -> String {
        switch n {
        case 1: return "1st"
        case 2: return "2nd"
        case 3: return "3rd"
        default: return "\(n)th"
        }
    }
}
