// The Contacts connector: connected, with the green dot, only once its person turned it on
// and iOS lets Steward AI read everyone or the people chosen; its switch off while iOS says
// no; the line under its name; and the people chosen as its page names them.

import XCTest
@testable import HouseholdAssistant

final class ContactsConnectorTests: XCTestCase {
    func testItIsConnectedOnlyWhenTurnedOnAndIOSAllowsIt() {
        let cases: [(isOn: Bool, access: PhoneAccessState, isConnected: Bool, isSwitchedOn: Bool, line: String)] = [
            (false, .notAsked, false, false, "Finds who a text is for"),
            (false, .allowed, false, false, "Finds who a text is for"),
            (false, .limited, false, false, "Finds who a text is for"),
            (false, .denied, false, false, "Off in your iPhone's Settings"),
            (true, .notAsked, false, true, "Finds who a text is for"),
            (true, .allowed, true, true, "All your contacts"),
            (true, .limited, true, true, "Only the people you chose"),
            (true, .denied, false, false, "Off in your iPhone's Settings"),
            (true, .unavailable, false, false, "Off in your iPhone's Settings"),
        ]
        for (isOn, access, isConnected, isSwitchedOn, line) in cases {
            // Act
            let connector = ContactsConnector(isOn: isOn, access: access)

            // Assert
            let label = "on \(isOn), \(access)"
            XCTAssertEqual(connector.isConnected, isConnected, label)
            XCTAssertEqual(connector.isSwitchedOn, isSwitchedOn, label)
            XCTAssertEqual(connector.line, line, label)
        }
    }

    func testThePeopleChosenAreNamedThreeAtATime() {
        let cases: [(names: [String], words: String?)] = [
            ([], nil),
            (["Gia"], "Gia"),
            (["Gia", "Mom", "Mike Rossi"], "Gia, Mom, Mike Rossi"),
            (["Gia", "Mom", "Mike Rossi", "Sarah Lee"], "Gia, Mom, Mike Rossi and 1 more"),
            (["Gia", "Mom", "Mike Rossi", "Sarah Lee", "Ann", "Bo"], "Gia, Mom, Mike Rossi and 3 more"),
        ]
        for (names, words) in cases {
            XCTAssertEqual(ContactsConnector.chosen(names), words, "\(names)")
        }
    }
}
