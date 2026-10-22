// A field nobody sees that opens the emoji keyboard, for reacting with any emoji past the
// five tapbacks, as Messages does. The first emoji typed is handed back once and the
// keyboard goes. Anything typed that is not one emoji (Tapback.reaction) is wiped, and
// putting the keyboard away ends it with nothing picked.

import SwiftUI
import UIKit

struct EmojiKeyboardField: UIViewRepresentable {
    @Binding var isOpen: Bool
    let onPick: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isOpen: $isOpen, onPick: onPick)
    }

    func makeUIView(context: Context) -> Field {
        let field = Field()
        field.delegate = context.coordinator
        field.autocorrectionType = .no
        field.addTarget(context.coordinator, action: #selector(Coordinator.typed(_:)), for: .editingChanged)
        return field
    }

    func updateUIView(_ field: Field, context: Context) {
        context.coordinator.isOpen = $isOpen
        context.coordinator.onPick = onPick
        if isOpen, !field.isFirstResponder {
            field.becomeFirstResponder()
        } else if !isOpen, field.isFirstResponder {
            field.resignFirstResponder()
        }
    }

    /// A text field whose keyboard is the emoji one, wherever the iPhone has it turned on.
    final class Field: UITextField {
        override var textInputMode: UITextInputMode? {
            UITextInputMode.activeInputModes.first { $0.primaryLanguage == "emoji" } ?? super.textInputMode
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextFieldDelegate {
        var isOpen: Binding<Bool>
        var onPick: (String) -> Void

        init(isOpen: Binding<Bool>, onPick: @escaping (String) -> Void) {
            self.isOpen = isOpen
            self.onPick = onPick
        }

        @objc func typed(_ field: UITextField) {
            let text = field.text ?? ""
            field.text = ""
            guard let emoji = Tapback.reaction(typed: text) else {
                return
            }
            isOpen.wrappedValue = false
            onPick(emoji)
        }

        func textFieldDidEndEditing(_ field: UITextField) {
            // Also called while the field is put away because `isOpen` already went false.
            if isOpen.wrappedValue {
                isOpen.wrappedValue = false
            }
        }
    }
}
