// A card's button and a link inside a bubble still answer a plain tap, now that a
// long-press opens the message menu and a left drag shows the times (build 14 audit,
// item 15). The demo puts a checklist and an @mention of Denise in Corey's message.

import XCTest

@MainActor
final class CardTapsTests: XCTestCase {
    nonisolated override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testACardsButtonAndAMentionInsideABubbleAnswerATap() throws {
        // Arrange
        let app = XCUIApplication()
        app.launchArguments = ["-StewardDemo", "YES", "-StewardCardTapsDemo", "YES"]
        app.launch()
        let pin = app.buttons["pin.direct"]
        XCTAssertTrue(pin.waitForExistence(timeout: 30))
        pin.tap()
        let item = app.buttons["Bring the garden notebook"]
        XCTAssertTrue(item.waitForExistence(timeout: 10), "the checklist's first item is not a button VoiceOver or a finger can reach")
        XCTAssertEqual(item.value as? String, "Not done")

        // Act
        item.tap()

        // Assert
        let ticked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Done"), object: item)
        XCTAssertEqual(XCTWaiter.wait(for: [ticked], timeout: 5), .completed, "a tap on the card's button did not tick it")
        XCTAssertFalse(app.buttons["Reply"].exists, "a tap opened the message menu")

        // Act
        let mention = app.links.matching(NSPredicate(format: "label CONTAINS %@", "Denise")).firstMatch
        XCTAssertTrue(mention.waitForExistence(timeout: 5), "the mention is not a link")
        mention.tap()

        // Assert
        let page = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "'s assistant")).firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 5), "a tap on the mention did not open Denise's page")
        XCTAssertFalse(app.buttons["Reply"].exists, "a tap on the mention opened the message menu")
    }
}
