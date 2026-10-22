// When a message card looks in Contacts: never while the Contacts switch is off, iOS's
// question the first time a drafted text needs it, a read without asking once iOS allows
// it, no access without asking once iOS said no, and nothing more once the card knows who
// or was sent.

import XCTest
@testable import HouseholdAssistant

final class ContactsLookupTests: XCTestCase {
    private static let draft = MessageCard(to: "Gia", text: "Running 10 minutes late, start without me.")
    private static let gia = MessageContact(id: "c-1", name: "Gia Marlowe", names: ["Gia", "Marlowe"], address: "+1 317 555 0142")
    private static let accesses: [PermissionStatus] = [.notAsked, .allowed, .denied]

    func testWithTheSwitchOffNoCardLooksInContacts() {
        for access in Self.accesses {
            XCTAssertEqual(ContactsLookup.step(for: MessageCardState(card: Self.draft), isContactsOn: false, access: access), .leave, "\(access)")
        }
    }

    func testTheFirstDraftedTextAsksIOSWhenItNeverHas() {
        XCTAssertEqual(ContactsLookup.step(for: MessageCardState(card: Self.draft), isContactsOn: true, access: .notAsked), .ask)
    }

    func testOnceIOSAllowsItACardReadsWithoutAsking() {
        XCTAssertEqual(ContactsLookup.step(for: MessageCardState(card: Self.draft), isContactsOn: true, access: .allowed), .read)
    }

    func testOnceIOSSaidNoACardSaysSoWithoutAsking() {
        XCTAssertEqual(ContactsLookup.step(for: MessageCardState(card: Self.draft), isContactsOn: true, access: .denied), .noAccess)
    }

    func testACardThatKnowsWhoNeverLooksAgain() {
        let recipients: [MessageRecipient] = [.one(Self.gia), .several([Self.gia]), .nobody, .noAccess]
        for recipient in recipients {
            // Arrange
            var state = MessageCardState(card: Self.draft)
            state.recipient = recipient

            for access in Self.accesses {
                // Act
                let step = ContactsLookup.step(for: state, isContactsOn: true, access: access)

                // Assert
                XCTAssertEqual(step, .leave, "\(recipient), \(access)")
            }
        }
    }

    func testASentCardNeverLooks() {
        // Arrange
        var state = MessageCardState(card: Self.draft)
        state.finish(.sent)

        // Act
        let step = ContactsLookup.step(for: state, isContactsOn: true, access: .notAsked)

        // Assert
        XCTAssertEqual(step, .leave)
    }
}
