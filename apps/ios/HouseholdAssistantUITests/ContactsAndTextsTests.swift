// The Contacts connector and the message card with the Simulator's own sample contacts,
// never a real person's. Contacts starts off; turning it on asks iOS, which the test answers
// for everyone, and the switch stays on with the row saying so. Then the texts Corey drafted
// (DemoContacts): one for Kate finds Kate Bell, one for Anna carries its event, and one for
// Zed finds nobody and offers Choose someone. The Simulator cannot send texts, so Apple's
// message sheet is left to the phone.

import XCTest

@MainActor
final class ContactsAndTextsTests: XCTestCase {
    nonisolated override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testTurningContactsOnAsksIOSAndTheSwitchStaysOn() throws {
        // Arrange
        let app = launched()
        let toggle = contactsSwitch(in: app)
        XCTAssertEqual(toggle.value as? String, "0", "Contacts is not off on a new phone")

        // Act
        toggle.tap()
        allowContacts(in: app)

        // Assert
        let isOn = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [isOn], timeout: 10), .completed, "the switch did not stay on once iOS said yes")
        XCTAssertTrue(labelled("All your contacts", in: app).waitForExistence(timeout: 5), "the row does not say every contact is shared")
    }

    func testDraftedTextsFindTheirPeopleInTheSimulatorsContacts() throws {
        // Arrange
        let app = launched()
        contactsSwitch(in: app).tap()
        allowContacts(in: app)
        app.tabBars.buttons["Chats"].tap()
        let pin = app.buttons["pin.direct"]
        XCTAssertTrue(pin.waitForExistence(timeout: 10))

        // Act
        pin.tap()

        // Assert
        XCTAssertTrue(found(app.buttons["message.choose-someone"], in: app), "the text for Zed offers no one to choose")
        XCTAssertTrue(found(app.descendants(matching: .any)["message.invite"], in: app), "the text for Anna lost its event")
        XCTAssertTrue(found(labelled("To Kate Bell", in: app), in: app), "the text for Kate did not find Kate Bell")
    }

    private func launched() -> XCUIApplication {
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .contacts)
        app.launchArguments = ["-StewardDemo", "YES", "-StewardContactsDemo", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["pin.direct"].waitForExistence(timeout: 30), "Chats never showed")
        return app
    }

    /// Settings, then Connectors, then the Contacts switch.
    private func contactsSwitch(in app: XCUIApplication) -> XCUIElement {
        app.tabBars.buttons["Settings"].tap()
        let connectors = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Connectors")).firstMatch
        XCTAssertTrue(connectors.waitForExistence(timeout: 10), "Connectors is gone from Settings")
        connectors.tap()
        let toggle = app.switches["connector.contacts.switch"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "Connectors has no Contacts switch")
        return toggle
    }

    /// Answers iOS's question about Contacts for everyone: its alert, then, on iOS 18 and
    /// later, its choice between some contacts and all of them. Four looks at most.
    private func allowContacts(in app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let yes = NSPredicate(
            format: "label IN %@ OR label BEGINSWITH %@ OR label CONTAINS[c] %@",
            ["Continue", "OK", "Allow"], "Share All", "Full Access"
        )
        for _ in 0..<4 {
            let candidates = [springboard.buttons.matching(yes).firstMatch, app.buttons.matching(yes).firstMatch]
            guard let button = candidates.first(where: { $0.waitForExistence(timeout: 3) }) else {
                return
            }
            button.tap()
        }
    }

    /// Anything on screen whose label holds `text`, a card's words inside a bubble included.
    private func labelled(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// Whether `element` shows in the thread, scrolling back through it a few times, since
    /// the thread opens at its newest message and keeps only what is near the screen.
    private func found(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<5 {
            if element.waitForExistence(timeout: 3) {
                return true
            }
            app.swipeDown()
        }
        return element.exists
    }
}
