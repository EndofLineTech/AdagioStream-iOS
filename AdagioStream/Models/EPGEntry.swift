import Foundation

/// One Electronic Program Guide entry — a scheduled show on a channel.
/// `id` is synthesized from `channelID` + `start.timeIntervalSince1970`,
/// so it remains stable across decode cycles.
public struct EPGEntry: Codable, Identifiable {
    public var id: String { "\(channelID)_\(start.timeIntervalSince1970)" }
    public let channelID: String
    public let title: String
    public let description: String?
    public let start: Date
    public let end: Date

    public init(
        channelID: String,
        title: String,
        description: String? = nil,
        start: Date,
        end: Date
    ) {
        self.channelID = channelID
        self.title = title
        self.description = description
        self.start = start
        self.end = end
    }

    /// True if `Date()` is between `start` (inclusive) and `end` (exclusive).
    public var isCurrentlyAiring: Bool {
        let now = Date()
        return now >= start && now < end
    }

    /// True if `Date()` is strictly before `start`.
    public var isUpcoming: Bool {
        Date() < start
    }

    /// Duration of the entry in whole minutes (rounded down).
    public var durationMinutes: Int {
        Int(end.timeIntervalSince(start) / 60)
    }
}
