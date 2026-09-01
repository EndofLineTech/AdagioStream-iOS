import Foundation
import SwiftUI

// AppSettings imports SwiftUI because `AppearanceMode` exposes a
// `ColorScheme?` and `TextSizeMode` exposes a `DynamicTypeSize?`. SwiftUI
// is available on both iOS 17+ and tvOS 17+, so accepting it as a Core
// dependency is the lowest-friction option per Phase 0 grooming.
// Trade-off: any future Core consumer that cannot import SwiftUI (e.g., a
// CLI tool or non-Apple-platform port) would need this type split into
// platform-agnostic core enums plus SwiftUI extensions. Revisit only if
// such a consumer appears.

/// Top-level appearance preference — system, light, or dark.
public enum AppearanceMode: String, Codable, CaseIterable {
    case system
    case light
    case dark

    public var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// SwiftUI `ColorScheme` mapping. `nil` defers to the system setting.
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Top-level text-size preference. `nil` defers to the system Dynamic Type
/// setting.
public enum TextSizeMode: String, Codable, CaseIterable {
    case system
    case xSmall
    case small
    case medium
    case large
    case xLarge
    case xxLarge
    case xxxLarge
    case accessibility1
    case accessibility2
    case accessibility3

    public var label: String {
        switch self {
        case .system: "System"
        case .xSmall: "XS"
        case .small: "S"
        case .medium: "M"
        case .large: "L"
        case .xLarge: "XL"
        case .xxLarge: "XXL"
        case .xxxLarge: "XXXL"
        case .accessibility1: "A1"
        case .accessibility2: "A2"
        case .accessibility3: "A3"
        }
    }

    public var dynamicTypeSize: DynamicTypeSize? {
        switch self {
        case .system: nil
        case .xSmall: .xSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .xLarge
        case .xxLarge: .xxLarge
        case .xxxLarge: .xxxLarge
        case .accessibility1: .accessibility1
        case .accessibility2: .accessibility2
        case .accessibility3: .accessibility3
        }
    }
}

/// What artwork a Now-Playing-style view shows for the current track.
public enum ArtworkDisplayMode: String, Codable, CaseIterable {
    case coverArt
    case channelLogo

    public var label: String {
        switch self {
        case .coverArt: "Cover Art"
        case .channelLogo: "Channel Logo"
        }
    }
}

/// Repeat mode for the library queue.
///
/// - off: Play through the queue once and stop at the end.
/// - all: Loop the whole queue; after the last track restart from index 0.
/// - one: Repeat the current track indefinitely on natural track-end
///        (auto-advance only).  Manual next/previous still moves to the
///        adjacent track — `.one` does NOT trap the user on one track.
public enum RepeatMode: String, Codable, CaseIterable {
    case off
    case all
    case one

    /// The mode that follows this one when the user cycles through.
    public var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }

    public var label: String {
        switch self {
        case .off: return "Off"
        case .all: return "All"
        case .one: return "One"
        }
    }
}

/// How channels are grouped in the browse UI.
public enum ChannelGroupingMode: String, Codable, CaseIterable {
    case allGroups
    case byProvider
    case bySource

    public var label: String {
        switch self {
        case .allGroups: "All Groups"
        case .byProvider: "By Provider"
        case .bySource: "By Source"
        }
    }
}

/// Sort order applied to channels (or groups) in browse views.
public enum ChannelSortOrder: String, Codable, CaseIterable {
    case providerOrder
    case natural
    case alphabetical

    public var label: String {
        switch self {
        case .providerOrder: "Provider Order"
        case .natural: "Natural Sort"
        case .alphabetical: "A–Z"
        }
    }
}

/// Podcast episode sort order (E3 / c2s.4). Drives both the episode list
/// display order (By Show + Recent Episodes) and whole-show auto-play
/// direction — see `PodcastEpisodeOrder` in AudiobookshelfModels.swift, which
/// this maps onto 1:1 at the settings boundary.
public enum PodcastEpisodeSortOrder: String, Codable, CaseIterable {
    case newestFirst
    case oldestFirst

    public var label: String {
        switch self {
        case .newestFirst: "Newest First"
        case .oldestFirst: "Oldest First"
        }
    }

    public var podcastEpisodeOrder: PodcastEpisodeOrder {
        switch self {
        case .newestFirst: .newestFirst
        case .oldestFirst: .oldestFirst
        }
    }
}

/// Ordering of the Navidrome music entries relative to streaming channel
/// groups in the CarPlay root list. Only meaningful when a Subsonic provider
/// is configured. `streamingFirst` preserves the historical layout (channels
/// above music).
public enum CarPlaySourceOrder: String, Codable, CaseIterable {
    case streamingFirst
    case navidromeFirst

    public var label: String {
        switch self {
        case .streamingFirst: "Streaming First"
        case .navidromeFirst: "Music First"
        }
    }
}

/// CarPlay-reconnect resume behavior (beads_mobilemusic-cpr). Controls what,
/// if anything, auto-plays when the CarPlay scene reconnects. Default `.off`
/// preserves the pre-existing deliberate "no auto-resume" behavior — this is
/// an opt-in override, not a replacement.
public enum CarPlayReconnectResume: String, Codable, CaseIterable {
    case off
    case lastPlayed
    case specific

    public var label: String {
        switch self {
        case .off: "Off"
        case .lastPlayed: "Last Played"
        case .specific: "Specific Station"
        }
    }
}

/// Stable identity for the user's chosen "Specific station" CarPlay-resume
/// target. `channelID` alone can collide across providers (Xtream/M3U ids
/// are provider-local), so `providerName` disambiguates and lets the target
/// survive a channel-list reload the same way `Channel.providerName` does.
public struct CarPlayResumeChannel: Codable, Equatable {
    public var channelID: String
    public var providerName: String?

    public init(channelID: String, providerName: String?) {
        self.channelID = channelID
        self.providerName = providerName
    }
}

/// Polling cadence for the ESPN scoreboard overlay.
public enum ESPNLivePollInterval: Int, Codable, CaseIterable {
    case off = 0
    case five = 5
    case ten = 10
    case fifteen = 15
    case thirty = 30

    public var label: String {
        self == .off ? "Off" : "\(rawValue)s"
    }
    public var interval: TimeInterval { TimeInterval(rawValue) }
}

/// User-configurable app settings. Persisted under
/// `Constants.StorageKeys.settings`. Tolerant decoder so older on-disk
/// data still loads even after fields are added.
public struct AppSettings: Codable {
    public var bufferDuration: TimeInterval
    public var appearanceMode: AppearanceMode
    public var textSizeMode: TextSizeMode
    public var sortPrefixes: [String]
    public var startupStreamID: String?
    public var channelSortOrder: ChannelSortOrder
    public var groupSortOrder: ChannelSortOrder
    public var debugLoggingEnabled: Bool
    public var artworkDisplayMode: ArtworkDisplayMode
    public var espnLivePollInterval: ESPNLivePollInterval
    public var channelGroupingMode: ChannelGroupingMode
    public var hasCompletedSetup: Bool
    /// Set to true after the one-time "We reorganized" tab tip is dismissed.
    /// False on first launch after the 0xy.5 tab restructure; persists thereafter.
    public var hasSeenTabReorgTip: Bool
    /// Library queue repeat mode (d6q.4). Does not affect radio.
    public var repeatMode: RepeatMode
    /// Library queue shuffle enabled (d6q.4). Does not affect radio.
    public var shuffleEnabled: Bool
    /// Offline mode (l31.3). When true, the Music tab restricts browsing to
    /// downloaded tracks only and no network browse/search calls are made.
    /// Default false (tolerant decodeIfPresent so old on-disk data loads safely).
    public var offlineMode: Bool
    /// CarPlay root ordering of Navidrome music vs streaming channel groups
    /// (fnv.8). Default streamingFirst preserves the historical layout.
    public var carPlaySourceOrder: CarPlaySourceOrder
    /// Podcast episode sort order (E3 / c2s.4). Drives both episode list
    /// display order and whole-show auto-play direction. Default newest-first.
    public var podcastEpisodeSortOrder: PodcastEpisodeSortOrder
    /// What to auto-play when a podcast episode ends (beads_mobilemusic-5aj.2).
    /// Default `.nextUnplayed` — can only advance into the future, so
    /// finishing the newest episode stops instead of replaying an older one.
    public var podcastEpisodeEndBehavior: PodcastEpisodeEndBehavior
    /// Auto-delete a downloaded episode once it's marked finished (E4 / 6b5.4).
    /// Default OFF — downloads persist until manually deleted. Audiobooks are
    /// never affected by this setting (episode-only trigger, see
    /// `AudioPlayerService.shouldAutoDeleteEpisode`).
    public var autoDeleteEpisodeAfterPlayed: Bool
    /// CarPlay-reconnect resume behavior (beads_mobilemusic-cpr). Default
    /// `.off` — existing users see no behavior change until they opt in.
    public var carPlayReconnectResume: CarPlayReconnectResume
    /// The user's chosen "Specific station" CarPlay-resume target. Only
    /// meaningful when `carPlayReconnectResume == .specific`; nil otherwise.
    public var carPlayReconnectSpecificChannel: CarPlayResumeChannel?
    /// Exact raw provider group names selected as SiriusXM-eligible. A set
    /// gives the same exact name one identity across provider accounts.
    public var selectedSXMGroupNames: Set<String>
    /// Separates a completed selection, including an intentional empty one,
    /// from settings that still require the one-time legacy migration.
    public var hasCompletedSXMGroupSelectionMigration: Bool

    public init(
        bufferDuration: TimeInterval = Constants.defaultBufferDuration,
        appearanceMode: AppearanceMode = .system,
        textSizeMode: TextSizeMode = .system,
        sortPrefixes: [String] = ["Radio: ", "TV: "],
        startupStreamID: String? = nil,
        channelSortOrder: ChannelSortOrder = .providerOrder,
        groupSortOrder: ChannelSortOrder = .providerOrder,
        debugLoggingEnabled: Bool = false,
        artworkDisplayMode: ArtworkDisplayMode = .coverArt,
        espnLivePollInterval: ESPNLivePollInterval = .fifteen,
        channelGroupingMode: ChannelGroupingMode = .allGroups,
        hasCompletedSetup: Bool = false,
        hasSeenTabReorgTip: Bool = false,
        repeatMode: RepeatMode = .off,
        shuffleEnabled: Bool = false,
        offlineMode: Bool = false,
        carPlaySourceOrder: CarPlaySourceOrder = .streamingFirst,
        podcastEpisodeSortOrder: PodcastEpisodeSortOrder = .newestFirst,
        podcastEpisodeEndBehavior: PodcastEpisodeEndBehavior = .nextUnplayed,
        autoDeleteEpisodeAfterPlayed: Bool = false,
        carPlayReconnectResume: CarPlayReconnectResume = .off,
        carPlayReconnectSpecificChannel: CarPlayResumeChannel? = nil,
        selectedSXMGroupNames: Set<String> = [],
        hasCompletedSXMGroupSelectionMigration: Bool = true
    ) {
        self.bufferDuration = bufferDuration
        self.appearanceMode = appearanceMode
        self.textSizeMode = textSizeMode
        self.sortPrefixes = sortPrefixes
        self.startupStreamID = startupStreamID
        self.channelSortOrder = channelSortOrder
        self.groupSortOrder = groupSortOrder
        self.debugLoggingEnabled = debugLoggingEnabled
        self.artworkDisplayMode = artworkDisplayMode
        self.espnLivePollInterval = espnLivePollInterval
        self.channelGroupingMode = channelGroupingMode
        self.hasCompletedSetup = hasCompletedSetup
        self.hasSeenTabReorgTip = hasSeenTabReorgTip
        self.repeatMode = repeatMode
        self.shuffleEnabled = shuffleEnabled
        self.offlineMode = offlineMode
        self.carPlaySourceOrder = carPlaySourceOrder
        self.podcastEpisodeSortOrder = podcastEpisodeSortOrder
        self.podcastEpisodeEndBehavior = podcastEpisodeEndBehavior
        self.autoDeleteEpisodeAfterPlayed = autoDeleteEpisodeAfterPlayed
        self.carPlayReconnectResume = carPlayReconnectResume
        self.carPlayReconnectSpecificChannel = carPlayReconnectSpecificChannel
        self.selectedSXMGroupNames = selectedSXMGroupNames
        self.hasCompletedSXMGroupSelectionMigration = hasCompletedSXMGroupSelectionMigration
    }

    /// Default settings used on first launch and after data deletion.
    public static let `default` = AppSettings()

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bufferDuration = try container.decode(TimeInterval.self, forKey: .bufferDuration)
        appearanceMode = try container.decode(AppearanceMode.self, forKey: .appearanceMode)
        textSizeMode = try container.decode(TextSizeMode.self, forKey: .textSizeMode)
        sortPrefixes = try container.decode([String].self, forKey: .sortPrefixes)
        startupStreamID = try container.decodeIfPresent(String.self, forKey: .startupStreamID)
        channelSortOrder = try container.decode(ChannelSortOrder.self, forKey: .channelSortOrder)
        groupSortOrder = try container.decode(ChannelSortOrder.self, forKey: .groupSortOrder)
        debugLoggingEnabled = try container.decode(Bool.self, forKey: .debugLoggingEnabled)
        artworkDisplayMode = try container.decodeIfPresent(ArtworkDisplayMode.self, forKey: .artworkDisplayMode) ?? .coverArt
        espnLivePollInterval = try container.decodeIfPresent(ESPNLivePollInterval.self, forKey: .espnLivePollInterval) ?? .fifteen
        channelGroupingMode = try container.decodeIfPresent(ChannelGroupingMode.self, forKey: .channelGroupingMode) ?? .allGroups
        hasCompletedSetup = try container.decodeIfPresent(Bool.self, forKey: .hasCompletedSetup) ?? false
        hasSeenTabReorgTip = try container.decodeIfPresent(Bool.self, forKey: .hasSeenTabReorgTip) ?? false
        repeatMode = try container.decodeIfPresent(RepeatMode.self, forKey: .repeatMode) ?? .off
        shuffleEnabled = try container.decodeIfPresent(Bool.self, forKey: .shuffleEnabled) ?? false
        offlineMode = try container.decodeIfPresent(Bool.self, forKey: .offlineMode) ?? false
        carPlaySourceOrder = try container.decodeIfPresent(CarPlaySourceOrder.self, forKey: .carPlaySourceOrder) ?? .streamingFirst
        podcastEpisodeSortOrder = try container.decodeIfPresent(PodcastEpisodeSortOrder.self, forKey: .podcastEpisodeSortOrder) ?? .newestFirst
        podcastEpisodeEndBehavior = try container.decodeIfPresent(PodcastEpisodeEndBehavior.self, forKey: .podcastEpisodeEndBehavior) ?? .nextUnplayed
        autoDeleteEpisodeAfterPlayed = try container.decodeIfPresent(Bool.self, forKey: .autoDeleteEpisodeAfterPlayed) ?? false
        carPlayReconnectResume = try container.decodeIfPresent(CarPlayReconnectResume.self, forKey: .carPlayReconnectResume) ?? .off
        carPlayReconnectSpecificChannel = try container.decodeIfPresent(CarPlayResumeChannel.self, forKey: .carPlayReconnectSpecificChannel)
        selectedSXMGroupNames = try container.decodeIfPresent(Set<String>.self, forKey: .selectedSXMGroupNames) ?? []
        hasCompletedSXMGroupSelectionMigration = try container.decodeIfPresent(Bool.self, forKey: .hasCompletedSXMGroupSelectionMigration) ?? false
    }
}

private struct TextSizeModifier: ViewModifier {
    let mode: TextSizeMode
    @Environment(\.dynamicTypeSize) private var systemSize

    func body(content: Content) -> some View {
        content.dynamicTypeSize(mode.dynamicTypeSize ?? systemSize)
    }
}

extension View {
    /// Applies a `TextSizeMode` to the receiver. `system` defers to the
    /// caller's existing dynamic-type environment.
    public func applyTextSize(_ mode: TextSizeMode) -> some View {
        modifier(TextSizeModifier(mode: mode))
    }
}
