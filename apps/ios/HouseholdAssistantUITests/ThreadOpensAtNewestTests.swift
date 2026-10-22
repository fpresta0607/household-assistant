import XCTest

@MainActor
final class ThreadOpensAtNewestTests: XCTestCase {
    nonisolated override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testALongThreadOpensAtItsNewestMessageAndKeepsTheNextInView() throws {
        // Arrange
        let app = XCUIApplication()
        let control = "steward-thread-layout-" + UUID().uuidString
        app.launchArguments = ["-StewardDemo", "YES", "-StewardLongThread", "YES", "-StewardThreadLayoutDemo", "YES", "-StewardThreadLayoutControl", control]
        app.launch()
        let pin = app.buttons["pin.direct"]
        XCTAssertTrue(pin.waitForExistence(timeout: 30))

        // Act
        pin.tap()
        let thread = app.collectionViews["room.thread"]
        XCTAssertTrue(thread.waitForExistence(timeout: 5))
        let field = app.descendants(matching: .any).matching(identifier: "composer.field").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let messages = thread.descendants(matching: .any).matching(identifier: "room.message")
        let newest = messages.matching(NSPredicate(format: "label CONTAINS %@", "A taller reply wraps onto several lines.")).firstMatch

        // Assert
        XCTAssertTrue(newest.waitForExistence(timeout: 5))
        XCTAssertTrue(newest.isHittable, "the thread opened above its newest message")
        XCTAssertGreaterThan(newest.frame.height, 30, "the message has no rendered text")
        XCTAssertGreaterThanOrEqual(newest.frame.minY, max(thread.frame.minY, app.navigationBars.firstMatch.frame.maxY))
        XCTAssertLessThanOrEqual(newest.frame.maxY, field.frame.minY, "the composer covers the newest message")

        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName((control + ".incoming") as CFString), nil, nil, true
        )
        let answer = messages.matching(NSPredicate(format: "label CONTAINS %@", "About 18 minutes now. Traffic is light.")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 30), "the incoming reply never arrived")
        XCTAssertTrue(answer.isHittable, "the next reply arrived below the screen")
        XCTAssertGreaterThan(answer.frame.height, 30, "the incoming reply has no rendered text")
        XCTAssertGreaterThanOrEqual(answer.frame.minY, max(thread.frame.minY, app.navigationBars.firstMatch.frame.maxY))
        XCTAssertLessThanOrEqual(answer.frame.maxY, field.frame.minY, "the composer covers the next reply")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
    }
}
