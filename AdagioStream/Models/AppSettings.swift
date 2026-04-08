import Foundation
import SwiftUI

enum AppearanceMode: String, Codable, CaseIterable {
    case system
    case light
    case dark

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum TextSizeMode: String, Codable, CaseIterable {
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

    var label: String {
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

    var dynamicTypeSize: DynamicTypeSize? {
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

enum ArtworkDisplayMode: String, Codable, CaseIterable {
    case coverArt
    case channelLogo

    var label: String {
        switch self {
        case .coverArt: "Cover Art"
        case .channelLogo: "Channel Logo"
        }
    }
}

enum ChannelGroupingMode: String, Codable, CaseIterable {
    case allGroups
    case byProvider
    case bySource

    var label: String {
        switch self {
        case .allGroups: "All Groups"
        case .byProvider: "By Provider"
        case .bySource: "By Source"
        }
    }
}

enum ChannelSortOrder: String, Codable, CaseIterable {
    case providerOrder
    case natural
    case alphabetical

    var label: String {
        switch self {
        case .providerOrder: "Provider Order"
        case .natural: "Natural Sort"
        case .alphabetical: "A–Z"
        }
    }
}

enum ESPNLivePollInterval: Int, Codable, CaseIterable {
    case five = 5
    case ten = 10
    case fifteen = 15
    case thirty = 30

    var label: String { "\(rawValue)s" }
    var interval: TimeInterval { TimeInterval(rawValue) }
}

struct AppSettings: Codable {
    var bufferDuration: TimeInterval
    var appearanceMode: AppearanceMode
    var textSizeMode: TextSizeMode
    var sortPrefixes: [String]
    var startupStreamID: String?
    var channelSortOrder: ChannelSortOrder
    var groupSortOrder: ChannelSortOrder
    var debugLoggingEnabled: Bool
    var artworkDisplayMode: ArtworkDisplayMode
    var espnLivePollInterval: ESPNLivePollInterval
    var channelGroupingMode: ChannelGroupingMode

    init(
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
        channelGroupingMode: ChannelGroupingMode = .allGroups
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
    }

    static let `default` = AppSettings()

    init(from decoder: Decoder) throws {
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
    func applyTextSize(_ mode: TextSizeMode) -> some View {
        modifier(TextSizeModifier(mode: mode))
    }
}
