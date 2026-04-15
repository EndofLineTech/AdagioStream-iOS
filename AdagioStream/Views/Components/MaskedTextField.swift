import SwiftUI
import UIKit

struct MaskedTextField: UIViewRepresentable {
    let placeholder: String
    @Binding var text: String
    private static let bullet = "\u{25CF}"

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.placeholder = placeholder
        field.textContentType = .init(rawValue: "")
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.delegate = context.coordinator
        field.font = .preferredFont(forTextStyle: .body)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        let masked = String(repeating: Self.bullet, count: text.count)
        if field.text != masked { field.text = masked }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            let current = text.wrappedValue
            guard let r = Range(range, in: current) else { return false }
            text.wrappedValue = current.replacingCharacters(in: r, with: string)
            let newMasked = String(repeating: MaskedTextField.bullet, count: text.wrappedValue.count)
            textField.text = newMasked
            let cursorOffset = range.location + string.count
            if let pos = textField.position(from: textField.beginningOfDocument, offset: cursorOffset) {
                textField.selectedTextRange = textField.textRange(from: pos, to: pos)
            }
            return false
        }
    }
}
