import Foundation

struct EPGEntry: Codable, Identifiable {
    var id: String { "\(channelID)_\(start.timeIntervalSince1970)" }
    let channelID: String
    let title: String
    let description: String?
    let start: Date
    let end: Date

    var isCurrentlyAiring: Bool {
        let now = Date()
        return now >= start && now < end
    }

    var isUpcoming: Bool {
        Date() < start
    }

    var durationMinutes: Int {
        Int(end.timeIntervalSince(start) / 60)
    }
}
