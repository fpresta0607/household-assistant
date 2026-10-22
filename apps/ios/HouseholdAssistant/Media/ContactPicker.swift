// The system's contact picker, put up over whatever is on screen. It runs outside the
// app, so it needs no permission to show the person's contacts, and it has to be
// presented by UIKit itself: wrapped in a SwiftUI sheet it closes as soon as it opens.

import ContactsUI
import UIKit

@MainActor
final class ContactPicker: NSObject, CNContactPickerDelegate {
    private var onPick: ((CNContact) -> Void)?

    /// Calls `onPick` with the contact chosen, and not at all when the picker is cancelled.
    func present(_ onPick: @escaping (CNContact) -> Void) {
        guard let top = UIApplication.shared.topmostViewController else {
            return
        }
        self.onPick = onPick
        let picker = CNContactPickerViewController()
        picker.delegate = self
        top.present(picker, animated: true)
    }

    func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
        onPick?(contact)
        onPick = nil
    }

    func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
        onPick = nil
    }
}
