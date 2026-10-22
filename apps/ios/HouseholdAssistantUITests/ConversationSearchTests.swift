// Searching a whole conversation from the plus menu, and what was shared from Chats (CFO
// notes section 5), on the demo's search thread (DemoSearchThread): 130 messages in
// Franco's own thread, so its oldest are only found once older pages are read.
//
// Search is the plus menu's last tile. What is typed lists every message that holds it
// with who, when and a line of it; a pick brings that message into view and lights it up
// a moment, which VoiceOver reads as selected; the arrows step to the older and newer
// matches. In the family room it finds what a voice note said. From Chats, search finds a
// photo by its caption and opens it.

import XCTest

// On the main actor, where XCUIApplication and every query live.
@MainActor
final class ConversationSearchTests: XCTestCase {
    nonisolated override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAPickBringsAMessageBeyondTheFirstPageIntoViewAndLightsItUp() throws {
        // Arrange
        let app = launch()
        openConversation("pin.direct", in: app)
        let field = openSearch(in: app)

        // Act
        field.typeText("plumber")
        let result = app.buttons.matching(identifier: "search.result").firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 20), "the search never found the first message. \(log(in: app))")
        keep(app, as: "search results")
        result.tap()

        // Assert
        // Looked for first, as the light lasts a few seconds and each look at the screen takes one.
        let lit = litMessage(in: app)
        XCTAssertTrue(lit.waitForExistence(timeout: 3), "no message lit up. \(log(in: app))")
        keep(app, as: "message found")
        XCTAssertTrue(lit.label.contains("The plumber comes"), "the message lit is not the one found: \(lit.label)")
        let message = self.message(containing: "The plumber comes", in: app)
        XCTAssertTrue(message.isHittable, "the message found is not on screen")
        XCTAssertEqual(app.buttons["search.list"].value as? String, "1 of 1")
        XCTAssertFalse(app.scrollViews["search.results"].exists, "picking a result did not collapse the popup")
        wait(until: "isSelected == false", for: message, "the message found stayed lit", timeout: 6)
    }

    func testTheArrowsStepThroughTheMatchesOlderAndNewer() throws {
        // Arrange
        let app = launch()
        openConversation("pin.direct", in: app)
        let field = openSearch(in: app)
        field.typeText("recital")
        let results = app.buttons.matching(identifier: "search.result")
        wait(until: "label == '3 results'", for: app.staticTexts["search.count"], "the search did not find the three mentions of the recital", timeout: 20)

        // Act
        results.element(boundBy: 0).tap()

        // Assert
        let position = app.buttons["search.list"]
        XCTAssertEqual(position.value as? String, "1 of 3")
        XCTAssertTrue(message(containing: "The recital starts at 6", in: app).isHittable, "the newest match is not on screen")
        app.buttons["search.older"].tap()
        XCTAssertEqual(position.value as? String, "2 of 3")
        XCTAssertTrue(message(containing: "recital program needs printing", in: app).waitForExistence(timeout: 5), "the older match is not on screen")
        app.buttons["search.older"].tap()
        XCTAssertEqual(position.value as? String, "3 of 3")
        XCTAssertTrue(message(containing: "recital moved to the school hall", in: app).waitForExistence(timeout: 5), "the oldest match is not on screen")
        XCTAssertFalse(app.buttons["search.older"].isEnabled, "there is no match older than the oldest")
        app.buttons["search.newer"].tap()
        XCTAssertEqual(position.value as? String, "2 of 3")
    }

    func testInTheFamilyRoomItFindsWhatAVoiceNoteSaid() throws {
        // Arrange
        let app = launch()
        openConversation("pin.family", in: app)
        let field = openSearch(in: app)

        // Act
        field.typeText("pasta")
        let result = app.buttons.matching(identifier: "search.result").firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 20), "the search did not find the voice note's words")
        result.tap()

        // Assert
        let lit = litMessage(in: app)
        XCTAssertTrue(lit.waitForExistence(timeout: 3), "no message lit up")
        XCTAssertTrue(lit.label.contains("Voice note"), "the message lit is not the voice note: \(lit.label)")
    }

    func testFromWhatWasSharedItFindsAPhotoByItsCaptionAndOpensIt() throws {
        // Arrange
        let app = launch()
        let search = app.buttons["shared.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10), "Chats shows no search of what was shared")
        search.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the shared search has no field")

        // Act
        field.tap()
        field.typeText("Seaside")
        let result = app.buttons.matching(identifier: "shared.result").firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 20), "the shared search did not find the beach photo")
        keep(app, as: "shared search")
        result.tap()

        // Assert
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 5), "the photo did not open")
    }

    func testSearchUsesTheBottomComposerAndLeavesTheChatVisibleInBothAppearances() throws {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            openConversation("pin.direct", in: app)
            let field = openSearch(in: app)
            let keyboard = app.keyboards.firstMatch
            XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
            XCTAssertFalse(app.scrollViews["search.results"].exists, "an empty query covered the chat")
            XCTAssertFalse(app.staticTexts["Search the whole conversation: words, voice notes, files and calls."].exists)
            XCTAssertFalse(app.buttons["search.older"].exists, "the detached keyboard toolbar is still present")
            // The text field's accessibility frame excludes its vertical padding, and
            // Keyboard excludes the system prediction strip. Measure the input row.
            let close = app.buttons["search.done"]
            let submit = app.buttons["search.submit"]
            XCTAssertLessThan(abs(keyboard.frame.minY - close.frame.maxY), 55, "search is not next to the keyboard")
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "room.message").allElementsBoundByIndex.contains { $0.isHittable }, "the chat is covered")
            keep(app, as: "search open \(appearance)")

            field.typeText("recital")
            let results = app.scrollViews["search.results"]
            XCTAssertTrue(results.waitForExistence(timeout: 10))
            wait(until: "label == '3 results'", for: app.staticTexts["search.count"], "results did not settle", timeout: 20)
            let headerBottom = app.buttons["room.header"].frame.maxY
            let inputTop = min(close.frame.minY, submit.frame.minY)
            XCTAssertLessThan(results.frame.height, (inputTop - headerBottom) * 0.6, "results cover too much of the chat")
            XCTAssertLessThanOrEqual(results.frame.maxY, inputTop, "results overlap the input")
            XCTAssertLessThan(inputTop - results.frame.maxY, 50, "results are detached from the composer")
            keep(app, as: "compact results \(appearance)")

            app.buttons["search.clear"].tap()
            wait(until: "exists == false", for: results, "clearing the query left an empty cover", timeout: 3)
            app.terminate()
        }
    }

    func testSearchKeepsAnUnsentMultilineDraftAndTheSubmitArrowOpensTheMatch() throws {
        let app = launch()
        openConversation("pin.direct", in: app)
        let draft = app.descendants(matching: .any).matching(identifier: "composer.field").firstMatch
        XCTAssertTrue(draft.waitForExistence(timeout: 5))
        draft.tap()
        draft.typeText("Remember this draft\nand this second line")
        let field = openSearch(in: app)
        field.typeText("plumber")
        app.buttons["search.submit"].tap()
        XCTAssertTrue(message(containing: "The plumber comes", in: app).waitForExistence(timeout: 20))
        XCTAssertFalse(app.scrollViews["search.results"].exists)
        app.buttons["search.done"].tap()
        XCTAssertEqual(draft.value as? String, "Remember this draft\nand this second line")
    }

    func testFiltersNarrowTheResultsAndCanBeClearedWithoutLosingTheQuery() throws {
        let app = launch()
        openConversation("pin.direct", in: app)
        let field = openSearch(in: app)
        field.typeText("recital")
        wait(until: "label == '3 results'", for: app.staticTexts["search.count"], "results did not settle", timeout: 20)
        app.buttons["search.filter.files"].tap()
        wait(until: "label == 'No results'", for: app.staticTexts["search.status"], "the file filter did not exclude text messages", timeout: 10)
        XCTAssertEqual(field.value as? String, "recital")
        app.buttons["search.filter.all"].tap()
        wait(until: "label == '3 results'", for: app.staticTexts["search.count"], "All did not restore the matches", timeout: 10)
    }

    // MARK: - Getting there

    /// The demo household with the search thread, on Chats, with no scene playing.
    private func launch(appearance: String = "automatic") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-StewardDemo", "YES", "-StewardSearchThread", "YES", "-StewardThreadLog", "YES", "-appearance", appearance]
        app.launch()
        XCTAssertTrue(app.buttons["pin.direct"].waitForExistence(timeout: 30), "Chats never showed")
        return app
    }

    private func openConversation(_ pin: String, in app: XCUIApplication) {
        app.buttons[pin].tap()
        XCTAssertTrue(app.collectionViews["room.thread"].waitForExistence(timeout: 10), "the thread never showed")
    }

    /// Opens search from the plus menu and hands back its field.
    private func openSearch(in app: XCUIApplication) -> XCUIElement {
        let plus = app.buttons["Add photos, files, your location and more"]
        XCTAssertTrue(plus.waitForExistence(timeout: 5), "the composer has no plus")
        plus.tap()
        let tile = app.buttons["Search"]
        XCTAssertTrue(tile.waitForExistence(timeout: 5), "the plus menu has no Search")
        keep(app, as: "plus menu")
        tile.tap()
        let field = app.descendants(matching: .any).matching(identifier: "search.field").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Search opened no field. \(app.debugDescription)")
        // It takes the keyboard as it opens; a tap makes sure before typing.
        field.tap()
        return field
    }

    /// The message a search just lit up, which VoiceOver reads as selected.
    private func litMessage(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND isSelected == true", "room.message"))
            .firstMatch
    }

    private func message(containing words: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "room.message", words))
            .firstMatch
    }

    /// What the thread's list logged last, for a failure to say how it moved (ThreadLog).
    private func log(in app: XCUIApplication) -> String {
        let element = app.descendants(matching: .any)["debug.threadLog"]
        return element.exists ? element.label : ""
    }

    private func wait(until condition: String, for object: Any, _ failure: String, timeout: TimeInterval) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: condition), object: object)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, failure)
    }

    /// The screen as it is, kept with the run for the Scrawl page.
    private func keep(_ app: XCUIApplication, as name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

