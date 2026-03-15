import Foundation

// MARK: - ESPN Scoreboard API Response

struct ESPNScoreboardResponse: Decodable {
    let events: [ESPNEvent]
}

struct ESPNEvent: Decodable, Identifiable {
    let id: String
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
    let outs: Int?
    let balls: Int?
    let strikes: Int?
    let onFirst: Bool?
    let onSecond: Bool?
    let onThird: Bool?
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
    let displayName: String            // "Boston Red Sox"
    let abbreviation: String           // "BOS"
}

struct ESPNRecord: Decodable {
    let name: String                   // "overall"
    let summary: String                // "9-11"
}

struct ESPNStatus: Decodable {
    let type: ESPNStatusType
}

struct ESPNStatusType: Decodable {
    let state: String                  // "pre", "in", "post"
    let shortDetail: String            // "3/15 - 1:05 PM EDT", "Bot 7th", "Final"
}

// MARK: - Resolved Game Info for Display

/// A matched ESPN game ready for display in a channel row.
struct ESPNGameInfo: Equatable {
    let awayAbbr: String               // "MIN"
    let homeAbbr: String               // "BOS"
    let awayScore: String              // "3"
    let homeScore: String              // "0"
    let awayRecord: String?            // "7-13-1"
    let homeRecord: String?            // "9-11"
    let state: GameState               // .pre, .live, .post
    let statusDetail: String           // "Bot 7th", "1:05 PM EDT", "Final"
    let outs: Int?                     // 0-3 during live game

    enum GameState: String, Equatable {
        case pre
        case live
        case post
    }

    /// Formatted one-liner for channel row subtitle.
    var displayText: String {
        switch state {
        case .pre:
            let awayRec = awayRecord.map { " (\($0))" } ?? ""
            let homeRec = homeRecord.map { " (\($0))" } ?? ""
            return "\(awayAbbr)\(awayRec) @ \(homeAbbr)\(homeRec) · \(statusDetail)"
        case .live:
            return "\(awayAbbr) \(awayScore) - \(homeAbbr) \(homeScore) · \(statusDetail)\(outsText)"
        case .post:
            return "\(awayAbbr) \(awayScore) - \(homeAbbr) \(homeScore) · \(statusDetail)"
        }
    }

    // MARK: - CarPlay / Now Playing (two-line display)

    /// Line 1: score line. e.g. "MIN 3 - BOS 5"
    var nowPlayingTitle: String {
        switch state {
        case .pre:
            let awayRec = awayRecord.map { " (\($0))" } ?? ""
            let homeRec = homeRecord.map { " (\($0))" } ?? ""
            return "\(awayAbbr)\(awayRec) @ \(homeAbbr)\(homeRec)"
        case .live, .post:
            return "\(awayAbbr) \(awayScore) - \(homeAbbr) \(homeScore)"
        }
    }

    /// Line 2: game status. e.g. "Bot 7th, 2 Outs"
    var nowPlayingSubtitle: String {
        switch state {
        case .live:
            return "\(statusDetail)\(outsText)"
        case .pre, .post:
            return statusDetail
        }
    }

    private var outsText: String {
        guard let outs else { return "" }
        return ", \(outs) \(outs == 1 ? "Out" : "Outs")"
    }
}
