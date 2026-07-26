import SwiftUI

/// Password field with a reveal/hide toggle, backed by native `SecureField`/
/// `TextField` rather than a custom UIKit bullet display.
///
/// beads_mobilemusic-uxb.2: the previous implementation was a `UITextField`
/// whose visible text was ALWAYS a bullet mask — the real password lived only
/// in the SwiftUI `Binding`. Giving that field `.password`/`.username`
/// content type (git history: a35aaa9, "Suppress iOS password autofill on
/// provider credential fields") would let iOS AutoFill try to save/suggest
/// the bullet string itself as the credential, since AutoFill's save-password
/// heuristic reads the field's displayed text, not the bound value. That's a
/// correctness reason to keep AutoFill off *for that field's display model*
/// — but it isn't a reason to go without AutoFill at all. Swapping to a
/// native SecureField/TextField pair sidesteps the whole problem: the
/// displayed text (in either mode) IS the real password, so `.password`
/// content type is safe, AutoFill save/fill works normally, and self-hosted
/// server passwords get a reveal toggle for free.
struct MaskedTextField: View {
    let placeholder: String
    @Binding var text: String
    /// Accessibility label for the field itself — e.g. "Xtream Codes
    /// password" — distinguishing it from the generic "Password"
    /// placeholder. Taken as a parameter rather than left for the call site
    /// to chain `.accessibilityLabel(...)` on the whole view: this view now
    /// contains two controls (the field and the reveal button), each of
    /// which needs its own label.
    var accessibilityLabel: String
    @State private var isRevealed = false
    /// `Bool?` (not `Bool`) so `.focused(_:equals:)` can address either the
    /// hidden or the visible field of the pair by which one is `true`/`false`;
    /// `nil` means neither currently has focus.
    @FocusState private var isFocused: Bool?

    var body: some View {
        HStack(spacing: 4) {
            // beads_mobilemusic-uxb kickback finding 3: an `if/else` swap
            // between concrete SecureField/TextField types breaks SwiftUI view
            // identity — toggling reveal mid-typing tore down and recreated
            // the field, dropping keyboard focus. Both fields now stay in the
            // hierarchy permanently, synced to the same `$text` binding, with
            // only the hidden one's hit-testing/visibility/focus toggled off —
            // so reveal never changes which view is "the" text field.
            ZStack(alignment: .leading) {
                SecureField(placeholder, text: $text)
                    .opacity(isRevealed ? 0 : 1)
                    .allowsHitTesting(!isRevealed)
                    .focused($isFocused, equals: false)
                    // uxd.4 (7): opacity+hit-testing hide the inactive field
                    // visually but leave it in the accessibility tree — a
                    // second VoiceOver stop for the same credential.
                    .accessibilityHidden(isRevealed)

                TextField(placeholder, text: $text)
                    .opacity(isRevealed ? 1 : 0)
                    .allowsHitTesting(isRevealed)
                    .focused($isFocused, equals: true)
                    // Revealed plaintext credentials must not hit the
                    // keyboard's learning cache.
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityHidden(!isRevealed)
            }
            .textContentType(.password)
            .accessibilityLabel(accessibilityLabel)

            Button {
                // Move focus to whichever field is about to become visible
                // BEFORE flipping isRevealed, so the keyboard never drops
                // between the two field identities.
                let wasFocused = isFocused != nil
                isRevealed.toggle()
                if wasFocused { isFocused = isRevealed }
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isRevealed ? "Hide password" : "Show password")
        }
    }
}
