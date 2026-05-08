import Foundation

// MARK: - ESPN Scoreboard API Response

public struct ESPNScoreboardResponse: Decodable {
    public let events: [ESPNEvent]
}

public struct ESPNEvent: Decodable, Identifiable {
    public let id: String
    public let date: String                   // ISO-8601 UTC, e.g. "2024-03-30T17:05Z"
    public let shortName: String              // "MIN @ BOS"
    public let competitions: [ESPNCompetition]

    public var competition: ESPNCompetition? { competitions.first }
}

public struct ESPNCompetition: Decodable {
    public let competitors: [ESPNCompetitor]
    public let status: ESPNStatus
    public let situation: ESPNSituation?

    public var homeTeam: ESPNCompetitor? { competitors.first(where: { $0.homeAway == "home" }) }
    public var awayTeam: ESPNCompetitor? { competitors.first(where: { $0.homeAway == "away" }) }
}

public struct ESPNSituation: Decodable {
    // MLB
    public let outs: Int?
    public let balls: Int?
    public let strikes: Int?
    public let onFirst: Bool?
    public let onSecond: Bool?
    public let onThird: Bool?
    // NFL
    public let possession: String?            // team ID with possession
    public let down: Int?
    public let distance: Int?
    public let yardLine: Int?
    public let downDistanceText: String?      // "1st & 10 at GB 25"
    public let shortDownDistanceText: String? // "1st & 10"
    public let possessionText: String?        // "Green Bay Packers"
}

public struct ESPNCompetitor: Decodable {
    public let homeAway: String               // "home" or "away"
    public let score: String                  // "0", "3", etc.
    public let team: ESPNTeam
    public let records: [ESPNRecord]?

    public var overallRecord: String? {
        records?.first(where: { $0.name == "overall" })?.summary
    }
}

public struct ESPNTeam: Decodable {
    public let id: String
    public let displayName: String            // "Boston Red Sox"
    public let abbreviation: String           // "BOS"
}

public struct ESPNRecord: Decodable {
    public let name: String                   // "overall"
    public let summary: String                // "9-11"
}

public struct ESPNStatus: Decodable {
    public let displayClock: String?          // "8:35", "0:00"
    public let period: Int?                   // 1, 2, 3, 4
    public let type: ESPNStatusType
}

public struct ESPNStatusType: Decodable {
    public let state: String                  // "pre", "in", "post"
    public let shortDetail: String            // "3/15 - 1:05 PM EDT", "Bot 7th", "Final"
}

// MARK: - League

public enum ESPNLeague: String, Equatable {
    case mlb
    case nba
    case nhl
    case nfl

    public var sportPath: String {
        switch self {
        case .mlb: return "baseball/mlb"
        case .nba: return "basketball/nba"
        case .nhl: return "hockey/nhl"
        case .nfl: return "football/nfl"
        }
    }

    public var periodName: String {
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
public struct ESPNGameInfo: Equatable {
    public let league: ESPNLeague
    public let awayAbbr: String               // "MIN"
    public let homeAbbr: String               // "BOS"
    public let awayScore: String              // "3"
    public let homeScore: String              // "0"
    public let awayRecord: String?            // "7-13-1"
    public let homeRecord: String?            // "9-11"
    public let state: GameState               // .pre, .live, .post
    public let statusDetail: String           // "Bot 7th", "8:35 - 1st", "Final"
    public let displayClock: String?          // "8:35"
    public let period: Int?                   // 1-4
    public let gameDate: Date?                // Parsed UTC start time from ESPN
    // MLB
    public let outs: Int?                     // 0-3 during live game
    public let balls: Int?                    // 0-3 during live at-bat
    public let strikes: Int?                  // 0-2 during live at-bat
    public let onFirst: Bool?                 // Runner on 1B
    public let onSecond: Bool?                // Runner on 2B
    public let onThird: Bool?                 // Runner on 3B
    // NFL
    public let possessionTeamAbbr: String?    // "GB" — team with the ball
    public let downDistanceText: String?      // "1st & 10"

    public init(
        league: ESPNLeague,
        awayAbbr: String,
        homeAbbr: String,
        awayScore: String,
        homeScore: String,
        awayRecord: String?,
        homeRecord: String?,
        state: GameState,
        statusDetail: String,
        displayClock: String?,
        period: Int?,
        gameDate: Date?,
        outs: Int?,
        balls: Int?,
        strikes: Int?,
        onFirst: Bool?,
        onSecond: Bool?,
        onThird: Bool?,
        possessionTeamAbbr: String?,
        downDistanceText: String?
    ) {
        self.league = league
        self.awayAbbr = awayAbbr
        self.homeAbbr = homeAbbr
        self.awayScore = awayScore
        self.homeScore = homeScore
        self.awayRecord = awayRecord
        self.homeRecord = homeRecord
        self.state = state
        self.statusDetail = statusDetail
        self.displayClock = displayClock
        self.period = period
        self.gameDate = gameDate
        self.outs = outs
        self.balls = balls
        self.strikes = strikes
        self.onFirst = onFirst
        self.onSecond = onSecond
        self.onThird = onThird
        self.possessionTeamAbbr = possessionTeamAbbr
        self.downDistanceText = downDistanceText
    }

    public enum GameState: String, Equatable {
        case pre
        case live = "in"
        case post
    }

    // MARK: - One-liner (channel row, mini player)

    public var displayText: String {
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
    public var nowPlayingTitle: String {
        switch state {
        case .pre:
            return "\(awayAbbr)\(recordText(awayRecord)) @ \(homeAbbr)\(recordText(homeRecord))"
        case .live, .post:
            return scoreLine
        }
    }

    /// Line 2: game status
    public var nowPlayingSubtitle: String {
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
