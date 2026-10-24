// Chats stays light: sharing where the iPhone is runs in the background with nothing on
// Chats, and Location in Settings is still where it is turned on or off. The Today card
// shows whole the first time each day, folds to a slim banner at the top once it is checked
// off or seen, and a tap on the banner opens the whole card again. The demo forgets what
// the phone kept each time it starts, so every launch is the day's first look. Each test
// keeps a picture of what it checked for the change's page.

import XCTest

// On the main actor, where XCUIApplication and every query live.
@MainActor
final class LighterChatsTests: XCTestCase {
    nonisolated override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSharingLocationPutsNothingOnChats() {
        // Arrange
        let app = launch(also: ["-StewardSharingLocation", "YES"])

        // Act
        keepPicture("chats.sharing-location")

        // Assert
        let chip = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", "your location")).firstMatch
        XCTAssertFalse(chip.exists, "Chats still shows that the location is shared")
        app.tabBars.buttons["Settings"].tap()
        let location = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Location")).firstMatch
        XCTAssertTrue(location.waitForExistence(timeout: 5), "Location is gone from Settings")
    }

    func testCheckingOffTheTodayCardFoldsItToABannerThatOpensItAgain() {
        // Arrange
        let app = launch()
        let card = app.buttons["today.card"]
        let banner = app.buttons["today.banner"]
        XCTAssertTrue(card.waitForExistence(timeout: 15), "the day's first look is not the whole card")
        keepPicture("chats.today.whole")

        // Act
        app.buttons["today.done"].tap()

        // Assert
        XCTAssertTrue(banner.waitForExistence(timeout: 5), "checked off, the card did not fold to a banner")
        XCTAssertFalse(card.exists, "the whole card is still there beside the banner")
        XCTAssertLessThan(banner.frame.height, 60, "the banner is not slim")
        XCTAssertLessThan(banner.frame.maxY, app.buttons["pin.direct"].frame.minY, "the banner is not at the top")
        XCTAssertTrue(banner.label.contains("Next, Dentist"), banner.label)
        keepPicture("chats.today.banner")

        // Act
        banner.tap()

        // Assert
        XCTAssertTrue(card.waitForExistence(timeout: 5), "a tap on the banner did not open the whole card")
        XCTAssertFalse(banner.exists)
    }

    func testTheTodayCardIsABannerOnceSeen() {
        // Arrange
        let app = launch()
        let card = app.buttons["today.card"]
        XCTAssertTrue(card.waitForExistence(timeout: 15), "the day's first look is not the whole card")
        let pin = app.buttons["pin.direct"]

        // Act
        pin.tap()
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 10), "Corey's thread never opened")
        back.tap()

        // Assert
        XCTAssertTrue(app.buttons["today.banner"].waitForExistence(timeout: 10), "seen once, the card did not fold to a banner")
        XCTAssertFalse(card.exists)
    }

    func testOpeningAConversationClearsItsUnreadCount() {
        for conversation in ["family", "direct"] {
            // Arrange
            let app = launch()
            let pin = app.buttons["pin.\(conversation)"]
            let otherPin = app.buttons[conversation == "family" ? "pin.direct" : "pin.family"]
            let unread = NSPredicate(format: "label CONTAINS %@", "2 unread")
            expectation(for: unread, evaluatedWith: pin)
            expectation(for: unread, evaluatedWith: otherPin)
            waitForExpectations(timeout: 10)
            keepPicture("chats.unread-count.\(conversation)")

            // Act
            pin.tap()
            let back = app.navigationBars.buttons.element(boundBy: 0)
            XCTAssertTrue(back.waitForExistence(timeout: 10))
            back.tap()

            // Assert
            let read = NSPredicate(format: "exists == true AND NOT label CONTAINS %@", "unread")
            expectation(for: read, evaluatedWith: pin)
            waitForExpectations(timeout: 10)
            XCTAssertTrue(unread.evaluate(with: otherPin))
            keepPicture("chats.unread-cleared.\(conversation)")
            app.terminate()
        }
    }

    // MARK: - The way there

    /// The demo on Chats, with nothing playing over it.
    private func launch(also arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-StewardDemo", "YES", "-StewardNetworkControl", "steward-chats-" + UUID().uuidString] + arguments
        app.launch()
        XCTAssertTrue(app.buttons["pin.direct"].waitForExistence(timeout: 30), "Chats never showed")
        return app
    }

    private func keepPicture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
