// Apple's contact picker, for who a drafted text goes to when the card found nobody or may
// not look: he picks a person, then the number or address to text. It runs outside the app,
// so it needs no permission and shows every contact whatever Steward AI may see, and the app
// learns only what he picked. Presented by UIKit itself, as the contact picker for a chat is.

import Contacts
import ContactsUI
import UIKit

@MainActor
final class RecipientPicker: NSObject, CNContactPickerDelegate {
    private var onPick: ((MessageContact) -> Void)?

    /// Calls `onPick` with the person and the number or address picked, and not at all when
    /// the picker is cancelled.
    func present(_ onPick: @escaping (MessageContact) -> Void) {
        guard let top = UIApplication.shared.topmostViewController else {
            return
        }
        self.onPick = onPick
        let picker = CNContactPickerViewController()
        picker.delegate = self
        picker.displayedPropertyKeys = [CNContactPhoneNumbersKey, CNContactEmailAddressesKey]
        picker.predicateForEnablingContact = NSPredicate(format: "phoneNumbers.@count > 0 OR emailAddresses.@count > 0")
        top.present(picker, animated: true)
    }

    func contactPicker(_ picker: CNContactPickerViewController, didSelect contactProperty: CNContactProperty) {
        defer {
            onPick = nil
        }
        let address: String
        switch contactProperty.value {
        case let number as CNPhoneNumber:
            address = number.stringValue
        case let email as String:
            address = email
        default:
            return
        }
        let contact = contactProperty.contact
        onPick?(MessageContact(id: contact.identifier, name: MessageContacts.name(of: contact) ?? address, names: [], address: address))
    }

    func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
        onPick = nil
    }
}
