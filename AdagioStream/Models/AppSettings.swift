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

struct AppSettings: Codable {
    var bufferDuration: TimeInterval
    var appearanceMode: AppearanceMode
    var textSizeMode: TextSizeMode

    init(
        bufferDuration: TimeInterval = Constants.defaultBufferDuration,
        appearanceMode: AppearanceMode = .system,
        textSizeMode: TextSizeMode = .system
    ) {
        self.bufferDuration = bufferDuration
        self.appearanceMode = appearanceMode
        self.textSizeMode = textSizeMode
    }

    static let `default` = AppSettings()
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
