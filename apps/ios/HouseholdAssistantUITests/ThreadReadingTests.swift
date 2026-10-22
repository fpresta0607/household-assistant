import XCTest

@MainActor
final class ThreadReadingTests: XCTestCase {
    nonisolated override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testIncomingReplyKeepsTheOlderMessageBeingReadInPlace() throws {
        // Arrange
        let app = XCUIApplication()
        let control = "steward-thread-layout-" + UUID().uuidString
        app.launchArguments = ["-StewardDemo", "YES", "-StewardLongThread", "YES", "-StewardThreadLayoutDemo", "YES", "-StewardThreadLayoutControl", control]
        app.launch()
        let pin = app.buttons["pin.direct"]
        XCTAssertTrue(pin.waitForExistence(timeout: 30))
        pin.tap()
        let thread = app.collectionViews["room.thread"]
        XCTAssertTrue(thread.waitForExistence(timeout: 5))
        let field = app.descendants(matching: .any).matching(identifier: "composer.field").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let messages = thread.descendants(matching: .any).matching(identifier: "room.message")
        let newest = messages.matching(NSPredicate(format: "label CONTAINS %@", "A taller reply wraps onto several lines.")).firstMatch
        XCTAssertTrue(newest.waitForExistence(timeout: 5))
        XCTAssertTrue(newest.isHittable)
        let older = messages.matching(NSPredicate(format: "label CONTAINS %@", "Yes. Games are Saturdays at 10 this fall")).firstMatch
        let visibleTop = max(thread.frame.minY, app.navigationBars.firstMatch.frame.maxY)
        let start = thread.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        let end = thread.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        for _ in 0..<8 {
            if older.exists && older.isHittable && older.frame.minY >= visibleTop
                && older.frame.maxY <= field.frame.minY && !(newest.exists && newest.isHittable) { break }
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        XCTAssertTrue(older.exists && older.isHittable, "the older message is not available to read")
        XCTAssertFalse(newest.exists && newest.isHittable, "the gesture did not leave the newest message")
        let before = try older.snapshot().frame
        XCTAssertGreaterThan(before.height, 30)
        XCTAssertGreaterThanOrEqual(before.minY, visibleTop)
        XCTAssertLessThanOrEqual(before.maxY, field.frame.minY)
        XCTAssertFalse(app.keyboards.firstMatch.exists, "the keyboard must be absent before the incoming reply")
        let applied = XCTDarwinNotificationExpectation(notificationName: control + ".applied")

        // Act
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName((control + ".incoming") as CFString), nil, nil, true
        )
        XCTAssertEqual(XCTWaiter.wait(for: [applied], timeout: 30), .completed, "RoomView never applied the incoming reply")

        // Assert
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard older.exists && older.isHittable else { return true }
            let frame = older.frame
            return abs(frame.minY - before.minY) > 1 || abs(frame.maxY - before.maxY) > 1
        }, object: nil)
        moved.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 3), .completed, "the incoming reply moved the message being read")
        let after = try older.snapshot().frame
        XCTAssertEqual(after.minY, before.minY, accuracy: 1)
        XCTAssertEqual(after.maxY, before.maxY, accuracy: 1)
        let incoming = messages.matching(NSPredicate(format: "label CONTAINS %@", "About 18 minutes now. Traffic is light.")).firstMatch
        XCTAssertFalse(incoming.exists && incoming.isHittable, "the incoming reply pulled the reader to the newest message")
        XCTAssertFalse(app.keyboards.firstMatch.exists)

        for _ in 0..<6 {
            if incoming.exists && incoming.isHittable && incoming.frame.minY >= visibleTop
                && incoming.frame.maxY <= field.frame.minY { break }
            thread.swipeUp(velocity: .fast)
        }
        XCTAssertTrue(incoming.waitForExistence(timeout: 10), "the incoming reply never appeared on return")
        XCTAssertTrue(incoming.isHittable, "returning to the newest left the incoming reply offscreen")
        let returned = try incoming.snapshot()
        XCTAssertTrue(returned.label.contains("About 18 minutes now. Traffic is light."))
        XCTAssertGreaterThan(returned.frame.height, 30, "the incoming reply has no rendered text")
        XCTAssertGreaterThanOrEqual(returned.frame.minY, visibleTop)
        XCTAssertLessThanOrEqual(returned.frame.maxY, field.frame.minY, "the composer covers the incoming reply")
    }

    func testReturningToAnOffscreenReplyShowsItsCompleteTextAndHeight() throws {
        // Arrange
        let app = XCUIApplication()
        app.launchArguments = ["-StewardDemo", "YES", "-StewardMotionDemo", "YES", "-StewardLongThread", "YES"]
        app.launch()
        let pin = app.buttons["pin.direct"]
        XCTAssertTrue(pin.waitForExistence(timeout: 30))
        pin.tap()
        let picture = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ AND NOT (label CONTAINS %@)", "Photo", "from"))
            .firstMatch
        XCTAssertTrue(picture.waitForExistence(timeout: 30))
        let thread = app.collectionViews["room.thread"]
        XCTAssertTrue(thread.waitForExistence(timeout: 5))
        let field = app.descendants(matching: .any).matching(identifier: "composer.field").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        field.typeText("Reading anchor")

        // Act
        app.buttons["Send"].tap()
        let start = thread.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        start.press(forDuration: 0.05, thenDragTo: end)
        let keyboardDismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [keyboardDismissed], timeout: 5), .completed)
        thread.swipeDown(velocity: .fast)
        let messages = thread.descendants(matching: .any).matching(identifier: "room.message")
        let answer = messages.matching(NSPredicate(format: "label CONTAINS %@", "That was your question Reading anchor.")).firstMatch
        XCTAssertFalse(answer.exists && answer.isHittable, "the gesture did not leave the newest reply")

        // Assert
        for _ in 0..<6 {
            if answer.exists && answer.isHittable && answer.frame.maxY <= field.frame.minY { break }
            thread.swipeUp(velocity: .fast)
        }
        XCTAssertTrue(answer.waitForExistence(timeout: 10), "the offscreen reply never finished")
        XCTAssertTrue(answer.isHittable, "returning to the newest left the answer offscreen")
        XCTAssertTrue(answer.label.contains("Morning"))
        XCTAssertTrue(answer.label.contains("Evening"))
        XCTAssertGreaterThan(answer.frame.height, 100, "the completed reply kept an empty or short bubble's height")
        XCTAssertLessThanOrEqual(answer.frame.maxY, field.frame.minY, "the composer covers the end of the reply")
    }
}
