// Static keyboard coverage and a reply arriving whole still self-size correctly. These checks
// complement ScrollHitchTests' interactive dismissal, which reproduces the keyboard crash.

import XCTest

@MainActor
final class ThreadRowsUnderTheKeyboardTests: XCTestCase {
    nonisolated override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testARowTheKeyboardCoversKeepsItsHeight() throws {
        // Arrange
        let app = launchThread()
        let thread = app.collectionViews["room.thread"]
        let field = app.descendants(matching: .any).matching(identifier: "composer.field").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let messages = [
            "A short message above the composer.",
            "A taller reply wraps onto several lines.",
        ].map { text in
            thread.descendants(matching: .any).matching(identifier: "room.message")
                .matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        }
        let frames = messages.map { message in
            XCTAssertTrue(message.waitForExistence(timeout: 5))
            XCTAssertTrue(message.isHittable)
            return message.frame
        }
        let composerTop = field.frame.minY

        // Act
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "no software keyboard rose: disconnect the simulator's hardware keyboard")

        // Assert
        XCTAssertGreaterThan(composerTop - field.frame.minY, 100)
        XCTAssertTrue(frames.contains { $0.maxY > field.frame.minY }, "the keyboard did not rise over a message's former position")
        for (message, before) in zip(messages, frames) {
            XCTAssertTrue(message.isHittable)
            XCTAssertGreaterThan(before.height, 30)
            XCTAssertEqual(message.frame.height, before.height, accuracy: 0.5, "the keyboard changed a bubble's height")
            XCTAssertLessThanOrEqual(message.frame.maxY, field.frame.minY)
        }
        field.typeText("Still focused")
        XCTAssertEqual(field.value as? String, "Still focused")

        let start = thread.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
        start.press(forDuration: 0.05, thenDragTo: end)
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        for _ in 0..<4 {
            if messages.allSatisfy({ $0.exists && $0.isHittable && $0.frame.maxY <= field.frame.minY }) { break }
            thread.swipeUp(velocity: .fast)
        }
        for (message, before) in zip(messages, frames) {
            XCTAssertTrue(message.isHittable)
            XCTAssertEqual(message.frame.height, before.height, accuracy: 0.5)
        }
    }

    /// The reply streams in over three stages the test advances, and shows only once it is
    /// complete, whole and at its full height, with the composer keeping its focus throughout.
    func testAReplyArrivesWholeWhileTheComposerHasFocus() throws {
        // Arrange
        let control = "steward-thread-layout-" + UUID().uuidString
        let app = launchThread(control: control)
        let field = app.descendants(matching: .any).matching(identifier: "composer.field").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let composerTop = field.frame.minY
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(composerTop - field.frame.minY, 100)
        field.typeText("Growing reply")
        app.buttons["Send"].tap()
        let answer = app.descendants(matching: .any).matching(identifier: "room.message")
            .matching(NSPredicate(format: "label CONTAINS %@", "Here is what I found.")).firstMatch
        let typing = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "is typing")).firstMatch
        XCTAssertTrue(typing.waitForExistence(timeout: 5), "Corey's typing row never showed")

        // Act
        for stage in 1...2 {
            let shownEarly = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: answer)
            shownEarly.isInverted = true
            XCTAssertEqual(XCTWaiter.wait(for: [shownEarly], timeout: 3), .completed, "stage \(stage) of the reply showed before it was complete")
            XCTAssertTrue(typing.exists, "the typing row went away at stage \(stage) of the reply")
            if stage == 1 {
                field.typeText("Still focused")
                XCTAssertEqual(field.value as? String, "Still focused", "the reply streaming in took focus from the composer")
            }
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName((control + ".advance") as CFString), nil, nil, true
            )
        }

        // Assert
        let completed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "That was your question Growing reply."), object: answer
        )
        XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 30), .completed)
        // Once it has glided to where it is read from.
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(answer.isHittable)
        XCTAssertTrue(answer.label.contains("Morning"))
        XCTAssertTrue(answer.label.contains("Evening"))
        XCTAssertGreaterThan(answer.frame.height, 100, "the reply arrived short of its full height")
        // Taller than what the keyboard leaves, it shows from its start, read from the top.
        // Its element reads up to a line above where it is drawn: on the hosted Mac (run
        // 39053749199) it said 110.7 points while the film drew the bubble's top at 128,
        // 12 below the bar, so a line is the slack.
        let visibleTop = max(app.collectionViews["room.thread"].frame.minY, app.navigationBars.firstMatch.frame.maxY)
        XCTAssertGreaterThanOrEqual(answer.frame.minY, visibleTop - 22, "the reply's start is hidden under the bar")
        XCTAssertLessThan(answer.frame.minY, field.frame.minY, "the reply's start is not on screen")
        XCTAssertFalse(typing.exists, "the typing row stayed under the reply")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        field.typeText(" again")
        XCTAssertEqual(field.value as? String, "Still focused again", "the reply arriving took focus from the composer")
    }

    private func launchThread(control: String = "steward-thread-layout-" + UUID().uuidString) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-StewardDemo", "YES", "-StewardLongThread", "YES", "-StewardThreadLayoutDemo", "YES", "-StewardThreadLayoutControl", control]
        app.launch()
        let pin = app.buttons["pin.direct"]
        XCTAssertTrue(pin.waitForExistence(timeout: 30))
        pin.tap()
        let newest = app.descendants(matching: .any).matching(identifier: "room.message")
            .matching(NSPredicate(format: "label CONTAINS %@", "A taller reply wraps onto several lines.")).firstMatch
        XCTAssertTrue(newest.waitForExistence(timeout: 5))
        return app
    }
}
