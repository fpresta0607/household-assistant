// With the network cut, the thread stays as it was and readable, the title says it is
// connecting in place of the name with no banner over the chat, and a message he sends
// waits in the thread marked as waiting. Once the network is back the message goes out by
// itself (CFO notes section 21e). The demo cuts and restores its own link on the test's cue
// (DemoGateway).

import XCTest

// On the main actor, where XCUIApplication and every query live.
@MainActor
final class NetworkCutTests: XCTestCase {
    nonisolated override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAMessageSentWithTheNetworkCutWaitsAndGoesOutWhenItIsBack() throws {
        // Arrange
        let app = XCUIApplication()
        let control = "steward-network-" + UUID().uuidString
        app.launchArguments = ["-StewardDemo", "YES", "-StewardNetworkControl", control]
        app.launch()
        let pin = app.buttons["pin.direct"]
        XCTAssertTrue(pin.waitForExistence(timeout: 30), "Chats never showed")
        pin.tap()
        let thread = app.collectionViews["room.thread"]
        let messages = thread.descendants(matching: .any).matching(identifier: "room.message")
        XCTAssertTrue(messages.firstMatch.waitForExistence(timeout: 10), "the thread never showed")
        let field = app.descendants(matching: .any).matching(identifier: "composer.field").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the message field is missing")
        let newestBefore = try XCTUnwrap(messages.allElementsBoundByIndex.last?.label, "no message on screen")

        // Act
        post(control + ".cut")
        let connecting = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Connecting")).firstMatch
        XCTAssertTrue(connecting.waitForExistence(timeout: 15), "the title never said it was connecting")
        field.tap()
        field.typeText("Sent with no network")
        app.buttons["Send"].tap()

        // Assert
        let sent = messages.matching(NSPredicate(format: "label CONTAINS %@", "Sent with no network")).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 5), "the message never showed in the thread")
        // The note sits under the bubble, as the note of a failed send does.
        let waiting = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Sends when you're back online")).firstMatch
        XCTAssertTrue(waiting.waitForExistence(timeout: 10), "the message was not marked as waiting")
        XCTAssertTrue(
            messages.matching(NSPredicate(format: "label == %@", newestBefore)).firstMatch.exists,
            "the thread lost what it showed before the link went down"
        )
        XCTAssertFalse(
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "out of reach")).firstMatch.exists,
            "a banner covers the chat while the link comes back"
        )

        post(control + ".restore")
        let wentOut = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: waiting)
        XCTAssertEqual(XCTWaiter.wait(for: [wentOut], timeout: 45), .completed, "the message never went out once the network was back")
        let receipt = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR label == %@", "Delivered", "Read")).firstMatch
        XCTAssertTrue(receipt.waitForExistence(timeout: 10), "the gateway never kept the message that waited")
        XCTAssertTrue(sent.exists)
    }

    private func post(_ name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true)
    }
}
