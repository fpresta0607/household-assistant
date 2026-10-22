// Pressing a message to react to it never moves or hides it: a finger held in the middle of
// a message taller than the screen opens the reactions and the menu beside the finger, on
// screen, with the message drawn exactly where it was, and when the menu closes the thread
// is just where it stood. The demo's long message is 64 paragraphs (DemoLongMessages).

import XCTest

// On the main actor, where XCUIApplication and every query live.
@MainActor
final class PressHoldsPlaceTests: XCTestCase {
    nonisolated override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testPressingTheMiddleOfALongMessageMovesNothing() throws {
        // Arrange
        let app = XCUIApplication()
        app.launchArguments = ["-StewardDemo", "YES", "-StewardMessageActionsDemo", "YES", "-StewardThreadLog", "YES"]
        app.launch()
        let pin = app.buttons["pin.direct"]
        XCTAssertTrue(pin.waitForExistence(timeout: 30), "Chats never showed")
        pin.tap()
        let thread = app.collectionViews["room.thread"]
        XCTAssertTrue(thread.waitForExistence(timeout: 10), "the thread never showed")
        let long = NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "room.message", "The complete message ends here.")
        let message = thread.descendants(matching: .any).matching(long).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 10), "the long message is missing")
        let screen = app.windows.firstMatch.frame
        for _ in 0..<12 {
            if message.frame.minY < screen.midY && message.frame.maxY > screen.midY {
                break
            }
            thread.swipeDown(velocity: .slow)
        }
        // The thread settles before the press.
        Thread.sleep(forTimeInterval: 1)
        let before = message.frame
        XCTAssertGreaterThan(before.height, screen.height, "the message is not taller than the screen")
        XCTAssertLessThan(before.minY, screen.midY)
        XCTAssertGreaterThan(before.maxY, screen.midY)
        let finger = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: before.minX + 40, dy: screen.midY))

        // Act
        finger.press(forDuration: 0.8)

        // Assert
        let reply = app.buttons["Reply"]
        XCTAssertTrue(reply.waitForExistence(timeout: 5), "the press did not open the menu")
        let thumbs = app.buttons["Thumbs up"]
        for control in [reply, thumbs] {
            XCTAssertTrue(control.isHittable, "\(control.label) is not on screen")
            XCTAssertTrue(screen.contains(control.frame), "\(control.label) is off screen at \(control.frame)")
        }
        XCTAssertLessThan(abs(reply.frame.midY - screen.midY), 320, "the menu opened far from the finger")
        // The row's element in the thread also takes in the reaction burst over the bubble's
        // top corner, so it reads a little higher and wider than the copy over the blur
        // (run 39057143853), and both are compared by their left and bottom edges.
        let drawn = app.descendants(matching: .any).matching(long).allElementsBoundByIndex.map(\.frame)
        XCTAssertEqual(drawn.count, 2, "the pressed message is not drawn over the blur: \(drawn)")
        for frame in drawn {
            XCTAssertEqual(frame.minX, before.minX, accuracy: 1, "the pressed message moved sideways: \(drawn) from \(before)")
            XCTAssertEqual(frame.maxY, before.maxY, accuracy: 1, "the pressed message moved: \(drawn) from \(before)")
        }

        // Act
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()

        // Assert
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: reply)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed, "the menu did not close")
        XCTAssertEqual(message.frame.minY, before.minY, accuracy: 1, "the thread moved while the menu was open")
    }
}
