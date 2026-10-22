// Hitches where the owner felt them, measured on Pearl's Mac preview run: Chats flung up
// and down, Corey's thread flung, the keyboard rising and falling in the thread, the
// thread opening and closing, and how long it takes to show its first messages.
//
// Each launches the demo household the way the motion film does (MotionDemoTests), with
// the film's scene, so nothing moves on its own until Franco opens his own thread, and
// then Corey answers once with a card and a picture. Whatever measures inside the thread
// lets that answer land first, so every iteration meets the same thread. The thread is a
// long one, 150 older messages, as a thread used for weeks is, and each message sent in it
// is answered at length, streamed in (DemoGateway's long thread), so the numbers are those
// of the thread the owner actually reads.
//
// Scrolling is measured by the system's scroll signposts, dragging and deceleration
// together (`scrollingAndDecelerationMetric`, which replaced the separate dragging and
// deceleration metrics), and by the hitches the app showed (`XCTHitchMetric`, iOS 26).
// Opening and closing are measured by the navigation transition signposts and the
// hitches, and the first messages by the clock, from the tap on the pin to the first
// message on screen.

import XCTest

// On the main actor, where XCUIApplication and every query live.
@MainActor
final class ScrollHitchTests: XCTestCase {
    nonisolated override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testScrollingChatsIsMeasured() throws {
        let app = launchDemo()
        let chats = app.scrollViews.containing(.button, identifier: "pin.direct").firstMatch
        XCTAssertTrue(chats.waitForExistence(timeout: 30), "Chats never showed")

        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric, XCTHitchMetric(application: app)], options: Self.fiveTimes()) {
            chats.swipeUp(velocity: .fast)
            chats.swipeDown(velocity: .fast)
        }
    }

    func testScrollingTheThreadIsMeasured() throws {
        let app = launchDemo()
        let thread = openThreadAndLetCoreyAnswer(in: app)

        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric, XCTHitchMetric(application: app)], options: Self.fiveTimes()) {
            // Down to read what came before, then back up to the newest.
            thread.swipeDown(velocity: .fast)
            thread.swipeUp(velocity: .fast)
        }
    }

    func testTheKeyboardInTheThreadIsMeasured() throws {
        let app = launchDemo()
        let thread = openThreadAndLetCoreyAnswer(in: app)
        let field = messageField(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the message field is missing")
        let keyboard = app.keyboards.firstMatch
        field.tap()
        // A simulator with a hardware keyboard connected shows no keyboard to measure.
        try XCTSkipUnless(keyboard.waitForExistence(timeout: 5), "no software keyboard rose: turn off I/O > Keyboard > Connect Hardware Keyboard")
        dismissKeyboard(by: thread, in: app)

        measure(metrics: [XCTHitchMetric(application: app), XCTClockMetric()], options: Self.fiveTimes()) {
            field.tap()
            XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "the keyboard never rose")
            dismissKeyboard(by: thread, in: app)
        }
    }

    /// A message sent and a long answer streaming in under it, read back while it arrives.
    func testAReplyStreamingInIsMeasured() throws {
        let app = launchDemo()
        let thread = openThreadAndLetCoreyAnswer(in: app)
        let field = messageField(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the message field is missing")
        var asked = 0

        measure(metrics: [XCTHitchMetric(application: app), XCTClockMetric()], options: Self.fiveTimes()) {
            asked += 1
            let question = "Question \(asked)"
            field.tap()
            field.typeText(question)
            app.buttons["Send"].tap()
            // The list extends behind the composer and keyboard. Keep both gestures
            // within the messages, where a person can actually drag them.
            let frame = thread.frame
            let top = max(frame.minY, app.navigationBars.firstMatch.frame.maxY)
            let bottom = min(frame.maxY, field.frame.minY)
            XCTAssertGreaterThan(bottom, top, "the thread has no visible space above the composer")
            let middle = (top + bottom) / 2
            let halfDistance = min(100, (bottom - top) / 3)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let upper = origin.withOffset(CGVector(dx: frame.midX, dy: middle - halfDistance))
            let lower = origin.withOffset(CGVector(dx: frame.midX, dy: middle + halfDistance))
            upper.press(forDuration: 0, thenDragTo: lower, withVelocity: .slow, thenHoldForDuration: 0)
            lower.press(forDuration: 0, thenDragTo: upper, withVelocity: .fast, thenHoldForDuration: 0)
            let answer = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "room.message", "That was your question \(question)."))
                .firstMatch
            XCTAssertTrue(answer.waitForExistence(timeout: 30), "the answer never finished")
            if app.keyboards.firstMatch.exists {
                dismissKeyboard(by: thread, in: app)
            }
        }
    }

    func testOpeningAndClosingTheThreadIsMeasured() throws {
        let app = launchDemo()
        _ = openThreadAndLetCoreyAnswer(in: app)
        backToChats(in: app)
        let pin = app.buttons["pin.direct"]
        let firstMessage = message(in: app)

        measure(metrics: [XCTOSSignpostMetric.navigationTransitionMetric, XCTHitchMetric(application: app)], options: Self.fiveTimes()) {
            pin.tap()
            XCTAssertTrue(firstMessage.waitForExistence(timeout: 10), "the thread never showed a message")
            backToChats(in: app)
        }
    }

    func testTheThreadsFirstMessagesAreMeasured() throws {
        let app = launchDemo()
        _ = openThreadAndLetCoreyAnswer(in: app)
        backToChats(in: app)
        let pin = app.buttons["pin.direct"]
        let firstMessage = message(in: app)
        let options = Self.fiveTimes()
        // Only the opening is timed: going back to Chats is each iteration's tidying up. The
        // transition itself is measured whole in testOpeningAndClosingTheThreadIsMeasured,
        // since here it may still be running when the first message shows.
        options.invocationOptions = [.manuallyStart, .manuallyStop]

        measure(metrics: [XCTClockMetric()], options: options) {
            startMeasuring()
            pin.tap()
            XCTAssertTrue(firstMessage.waitForExistence(timeout: 10), "the thread never showed a message")
            stopMeasuring()
            backToChats(in: app)
        }
    }

    // MARK: - Getting there

    private static func fiveTimes() -> XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        return options
    }

    /// The demo household in the motion film's scene with the long thread, on Chats.
    private func launchDemo() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-StewardDemo", "YES", "-StewardMotionDemo", "YES", "-StewardLongThread", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["pin.direct"].waitForExistence(timeout: 30), "Corey's pin never showed")
        return app
    }

    /// Opens Corey's thread from his pin and waits for his answer and its picture, the
    /// scene's last word, then gives the picture a moment to come into focus. Returns the
    /// thread's scroll view (ThreadList).
    private func openThreadAndLetCoreyAnswer(in app: XCUIApplication) -> XCUIElement {
        app.buttons["pin.direct"].tap()
        let picture = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ AND NOT (label CONTAINS %@)", "Photo", "from"))
            .firstMatch
        XCTAssertTrue(picture.waitForExistence(timeout: 30), "Corey's picture never arrived")
        settle(1.5)
        let thread = app.collectionViews["room.thread"]
        XCTAssertTrue(thread.waitForExistence(timeout: 5), "the thread's messages are missing")
        return thread
    }

    /// Any message in the open thread (RoomBubble).
    private func message(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "room.message").firstMatch
    }

    /// The composer's field, by its identifier: iOS reports it as a text view or a text
    /// field, and its placeholder is gone once it is focused or holds words, so neither the
    /// type nor the placeholder finds it every time.
    private func messageField(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "composer.field").firstMatch
    }

    /// Drags the thread down past the top of the keyboard, which the thread lets go of
    /// interactively, and waits until it has gone.
    private func dismissKeyboard(by thread: XCUIElement, in app: XCUIApplication) {
        let start = thread.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
        start.press(forDuration: 0.05, thenDragTo: end)
        wait(until: "exists == false", for: app.keyboards.firstMatch, "the keyboard never went down")
    }

    /// Back from the thread to Chats, once Chats can be tapped again.
    private func backToChats(in app: XCUIApplication) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
        wait(until: "isHittable == true", for: app.buttons["pin.direct"], "Chats never came back")
    }

    private func wait(until condition: String, for element: XCUIElement, _ failure: String) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: condition), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed, failure)
    }

    /// Lets what is on screen finish before anything is measured.
    private func settle(_ seconds: TimeInterval) {
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "the screen settles")], timeout: seconds)
    }
}
