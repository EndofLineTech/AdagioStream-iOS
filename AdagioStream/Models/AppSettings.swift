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
        hasCompletedSetup: Bool = false
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
