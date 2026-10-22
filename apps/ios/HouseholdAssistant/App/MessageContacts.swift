// Finds who a message card is for in this iPhone's Contacts, by the name the assistant
// used, once the Contacts connector is on. It asks iOS only if the connector was turned on
// before iOS ever asked (ContactsLookup), reads on the phone, and sends nothing anywhere:
// the name goes no further than Contacts and the match no further than the card.

import Contacts
import Foundation

enum MessageContacts {
    /// Where Contacts stands for Steward AI, read without asking.
    static var access: PermissionStatus {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .notDetermined:
            return .notAsked
        case .authorized, .limited:
            return .allowed
        case .denied, .restricted:
            return .denied
        @unknown default:
            return .denied
        }
    }

    /// The contacts `name` finds, asking iOS first if it never has, nil when Steward AI
    /// may not read Contacts.
    static func find(_ name: String) async -> [MessageContact]? {
        switch access {
        case .notAsked:
            guard (try? await CNContactStore().requestAccess(for: .contacts)) == true else {
                return nil
            }
        case .allowed:
            break
        case .denied:
            return nil
        }
        return read(name)
    }

    /// The people iOS lets Steward AI see while its person shares only some, by name, for
    /// the Contacts page to show and nothing else.
    static func chosenNames() async -> [String] {
        let request = CNContactFetchRequest(keysToFetch: [CNContactFormatter.descriptorForRequiredKeys(for: .fullName)])
        var names: [String] = []
        try? CNContactStore().enumerateContacts(with: request) { contact, _ in
            if let name = CNContactFormatter.string(from: contact, style: .fullName), !name.isEmpty {
                names.append(name)
            }
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// A contact's whole name, when the contact carries what it takes to write one: one
    /// from Apple's picker may carry only what was picked.
    static func name(of contact: CNContact) -> String? {
        guard contact.areKeysAvailable([CNContactFormatter.descriptorForRequiredKeys(for: .fullName)]) else {
            return nil
        }
        return CNContactFormatter.string(from: contact, style: .fullName)
    }

    /// Synchronous, which is why `find` is async and runs off the main actor.
    private static func read(_ name: String) -> [MessageContact]? {
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
        ]
        let predicate = CNContact.predicateForContacts(matchingName: name)
        guard let found = try? CNContactStore().unifiedContacts(matching: predicate, keysToFetch: keys) else {
            return nil
        }
        return found.map { contact in
            MessageContact(
                id: contact.identifier,
                name: CNContactFormatter.string(from: contact, style: .fullName) ?? contact.givenName,
                names: [contact.givenName, contact.familyName, contact.nickname].filter { !$0.isEmpty },
                address: address(of: contact)
            )
        }
    }

    /// Where a text reaches them best: an iPhone or mobile number, any number, then an
    /// email address, which iMessage reaches too.
    private static func address(of contact: CNContact) -> String? {
        let mobile = contact.phoneNumbers.first { $0.label == CNLabelPhoneNumberiPhone || $0.label == CNLabelPhoneNumberMobile }
        let number = (mobile ?? contact.phoneNumbers.first)?.value.stringValue
        return number ?? contact.emailAddresses.first.map { String($0.value) }
    }
}
