// Going back from a chat to Chats shows no white card mid-way (CFO notes section 9). The
// app measures its own window on every frame of the way back, since a UI test only sees
// the screen once the transition is over (DemoBackTransitionObservation), and says clean
// or flash.

import XCTest

@MainActor
final class BackTransitionTests: XCTestCase {
    nonisolated override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testGoingBackFromEachChatToChatsFlashesNothingWhite() throws {
        // Arrange
        let app = XCUIApplication()
        let control = "steward-back-transition-" + UUID().uuidString
        // The thread layout demo, so no scripted scene moves between chats meanwhile.
        app.launchArguments = [
            "-StewardDemo", "YES", "-StewardThreadLayoutDemo", "YES", "-StewardBackTransitionControl", control,
        ]
        app.launch()

        for conversation in ["direct", "family"] {
            let pin = app.buttons["pin.\(conversation)"]
            XCTAssertTrue(pin.waitForExistence(timeout: 30))
            pin.tap()
            XCTAssertTrue(app.descendants(matching: .any)["composer.field"].waitForExistence(timeout: 10))
            let clean = XCTDarwinNotificationExpectation(notificationName: control + ".back-clean")

            // Act
            app.navigationBars.buttons.element(boundBy: 0).tap()

            // Assert
            XCTAssertEqual(
                XCTWaiter.wait(for: [clean], timeout: 5), .completed,
                "going back from \(conversation) drew a white flash, or was never measured"
            )
        }
    }
}
