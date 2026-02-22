import SwiftUI

// MARK: - Glass Background Modifier

/// Replaces `.background(.ultraThinMaterial)` with `.glassEffect(.regular)` on iOS 26+.
struct GlassBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(.regular)
        } else {
            content.background(.ultraThinMaterial)
        }
    }
}

// MARK: - Interactive Glass Button Style

/// Uses `.glass` button style on iOS 26+, subtle scale fallback on older.
struct InteractiveGlassButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        if #available(iOS 26, *) {
            Button(configuration)
                .buttonStyle(.glass)
        } else {
            Button(configuration)
                .buttonStyle(.plain)
        }
    }
}

// MARK: - Glass Container Modifier

/// Wraps content in `GlassEffectContainer` on iOS 26+ for grouped glass effects.
struct GlassContainerModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            GlassEffectContainer {
                content
            }
        } else {
            content
        }
    }
}

// MARK: - View Extensions

extension View {
    /// Applies glass background on iOS 26+, `.ultraThinMaterial` on older.
    func glassBackground() -> some View {
        modifier(GlassBackgroundModifier())
    }

    /// Wraps in a `GlassEffectContainer` on iOS 26+ for grouped glass effects.
    func glassContainer() -> some View {
        modifier(GlassContainerModifier())
    }
}
