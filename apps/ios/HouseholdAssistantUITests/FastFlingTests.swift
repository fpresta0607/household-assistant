// A fast fling up through a long thread of mixed rows, the way the owner reads back
// through his own (CFO notes sections 3 and 4): long replies, photos, bar and line charts,
// voice notes with their words, voice replies and calls, 300 of them (DemoFlingThread).
//
// The fling is measured by the hitches the app showed (`XCTHitchMetric`) and the system's
// scroll signposts, and so is a slow scroll up the same thread, which must not change.
// What each fling cost the app, row by row and frame by frame, is read from the app's own
// log (ThreadFlingLog) in a launch of its own, since keeping that log costs the app too,
// and printed for the run's log. And while a reply streams in, a fast fling up and back
// draws no message over another and leaves the thread where the fling left it.
//
// A voice note shows only itself until it is tapped off its play button, which shows its
// Transcript, and a tap on that opens its words, each time growing the note downward with
// nothing drawn over it. Flung away and back, it shows only itself again.

import XCTest

// On the main actor, where XCUIApplication and every query live.
@MainActor
final class FastFlingTests: XCTestCase {
    private static let newest = "Fling thread newest message."

    nonisolated override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testFlingingUpFastIsMeasured() throws {
        let app = launch()
        let thread = openThread(in: app)

        measure(metrics: metrics(app), options: Self.fiveTimesByHand()) {
            startMeasuring()
            for _ in 0..<3 {
                thread.swipeDown(velocity: .fast)
            }
            stopMeasuring()
            backToNewest(in: app)
        }
    }

    func testScrollingUpSlowlyIsMeasured() throws {
        let app = launch()
        let thread = openThread(in: app)
        let (upper, lower) = dragPoints(across: thread, in: app)

        measure(metrics: metrics(app), options: Self.fiveTimesByHand()) {
            startMeasuring()
            for _ in 0..<3 {
                // Held a moment at the end, so the thread stops where the finger does.
                upper.press(forDuration: 0.05, thenDragTo: lower, withVelocity: .slow, thenHoldForDuration: 0.2)
            }
            stopMeasuring()
            backToNewest(in: app)
        }
    }

    func testWhatEachFlingCostsIsLogged() throws {
        // Arrange
        let app = launch(also: ["-StewardThreadLog", "YES"])
        let thread = openThread(in: app)
        var costs: [String] = []
        // Each fling's cost and each time rows were built ahead while the thread rested, in turn.
        var lines: [String] = []
        func keepNewLines() {
            let log = app.descendants(matching: .any)["debug.threadLog"].label.components(separatedBy: " | ")
            lines += log.filter { ($0.hasPrefix("fling built") || $0.hasPrefix("built ahead")) && !lines.contains($0) }
        }

        // Act
        for _ in 0..<6 {
            keepNewLines()
            thread.swipeDown(velocity: .fast)
            costs.append(nextFlingCost(after: costs.last, in: app))
            keepNewLines()
        }

        // Assert
        let report = lines.joined(separator: "\n")
        print("What each fast fling up cost the app:\n\(report)")
        let attachment = XCTAttachment(string: report)
        attachment.name = "fling costs"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertFalse(costs.contains(""), "a fling wrote no cost to the log: \(report)")
    }

    func testFlingingWhileAReplyStreamsDrawsNoMessageOverAnother() throws {
        // Arrange
        let app = launch()
        let thread = openThread(in: app)
        let field = app.descendants(matching: .any).matching(identifier: "composer.field").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the message field is missing")
        field.tap()
        field.typeText("Question 1")
        app.buttons["Send"].tap()

        // Act
        for _ in 0..<2 {
            thread.swipeDown(velocity: .fast)
            try assertNoMessageOverAnother(in: thread, "flung up while the reply streamed")
        }
        let left = try readMessage(in: thread)
        settle(1.5)
        let after = try readMessage(in: thread)
        for _ in 0..<2 {
            thread.swipeUp(velocity: .fast)
            try assertNoMessageOverAnother(in: thread, "flung back down while the reply streamed")
        }

        // Assert
        XCTAssertEqual(after.label, left.label, "the message read changed while nothing touched the thread")
        XCTAssertEqual(after.minY, left.minY, accuracy: 1, "the thread moved while the reply streamed: \(left.minY) to \(after.minY)")
        let jump = app.buttons["thread.jumpToNewest"]
        if jump.waitForExistence(timeout: 2) {
            jump.tap()
        }
        let answer = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "room.message", "That was your question Question 1."))
            .firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 40), "the answer never finished")
        try assertNoMessageOverAnother(in: thread, "once the reply was in")
    }

    func testAVoiceNoteShowsItsTranscriptOnlyWhenTapped() throws {
        // Arrange
        let app = launch()
        let thread = openThread(in: app)
        let note = try XCTUnwrap(scrollToVoiceNote(across: thread, in: app), "no voice note of Franco's came on screen")
        let closed = note.frame

        // Act
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: closed.maxX - 50, dy: closed.maxY - 30)).tap()

        // Assert
        let offered = note.frame
        XCTAssertGreaterThan(offered.height, closed.height + 10, "a tap on the note showed no Transcript under it")
        XCTAssertLessThan(offered.height, closed.height + 40, "a tap on the note opened more than its Transcript")
        XCTAssertEqual(offered.minY, closed.minY, accuracy: 1, "the note moved when it showed its Transcript")
        try assertNoMessageOverAnother(in: thread, "with the Transcript shown")

        // Act
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: offered.minX + 50, dy: offered.maxY - 20)).tap()

        // Assert
        let open = note.frame
        XCTAssertGreaterThan(open.height, offered.height + 10, "a tap on the Transcript did not open the words")
        XCTAssertEqual(open.minY, closed.minY, accuracy: 1, "the note moved when it opened its words")
        try assertNoMessageOverAnother(in: thread, "with the words open")

        // Act
        for _ in 0..<2 {
            thread.swipeDown(velocity: .fast)
        }
        backToNewest(in: app)
        let back = try XCTUnwrap(scrollToVoiceNote(across: thread, in: app), "no voice note of Franco's came back on screen")

        // Assert
        XCTAssertEqual(back.frame.height, closed.height, accuracy: 1, "the note came back still showing its words or its Transcript")
    }

    // MARK: - Getting there

    /// Drags the thread slowly down from the newest, a little at a time, until one of
    /// Franco's own voice notes is wholly in sight, and hands it back. Above the newest, the
    /// thread keeps its place when a row changes height, rather than its bottom.
    private func scrollToVoiceNote(across thread: XCUIElement, in app: XCUIApplication) -> XCUIElement? {
        let (upper, lower) = dragPoints(across: thread, in: app)
        let notes = thread.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND label BEGINSWITH %@", "room.message", "Voice note"))
        for _ in 0..<8 {
            upper.press(forDuration: 0.05, thenDragTo: lower, withVelocity: .slow, thenHoldForDuration: 0.3)
            let sight = uncovered(by: thread, in: app)
            if let note = notes.allElementsBoundByIndex.first(where: { sight.contains($0.frame) }) {
                return note
            }
        }
        return nil
    }

    /// The part of the thread between the bar above and the composer below.
    private func uncovered(by thread: XCUIElement, in app: XCUIApplication) -> CGRect {
        let frame = thread.frame
        let field = app.descendants(matching: .any).matching(identifier: "composer.field").firstMatch
        let top = max(frame.minY, app.navigationBars.firstMatch.frame.maxY)
        let bottom = field.exists ? min(frame.maxY, field.frame.minY) : frame.maxY
        return CGRect(x: frame.minX, y: top, width: frame.width, height: bottom - top)
    }

    private static func fiveTimesByHand() -> XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        return options
    }

    private func metrics(_ app: XCUIApplication) -> [XCTMetric] {
        [XCTHitchMetric(application: app), XCTOSSignpostMetric.scrollingAndDecelerationMetric]
    }

    /// The demo household with Franco's thread of 300 mixed rows, on Chats.
    private func launch(also arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-StewardDemo", "YES", "-StewardFlingThread", "YES"] + arguments
        app.launch()
        XCTAssertTrue(app.buttons["pin.direct"].waitForExistence(timeout: 30), "Chats never showed")
        return app
    }

    /// Opens Franco's own thread at its newest message and lets it settle. Returns the
    /// thread's list (ThreadCollection).
    private func openThread(in app: XCUIApplication) -> XCUIElement {
        app.buttons["pin.direct"].tap()
        XCTAssertTrue(newestMessage(in: app).waitForExistence(timeout: 20), "the thread never showed its newest message")
        settle(1.5)
        let thread = app.collectionViews["room.thread"]
        XCTAssertTrue(thread.waitForExistence(timeout: 5), "the thread's list is missing")
        return thread
    }

    private func newestMessage(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "room.message", Self.newest))
            .firstMatch
    }

    /// Back down to the newest message by the thread's own jump, out of what is measured.
    private func backToNewest(in app: XCUIApplication) {
        let jump = app.buttons["thread.jumpToNewest"]
        XCTAssertTrue(jump.waitForExistence(timeout: 5), "no control to jump to the newest")
        jump.tap()
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: newestMessage(in: app))
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 10), .completed, "the jump never reached the newest message")
        settle(1)
    }

    /// Two points a third of the thread's uncovered height apart, the upper one first.
    private func dragPoints(across thread: XCUIElement, in app: XCUIApplication) -> (XCUICoordinate, XCUICoordinate) {
        let sight = uncovered(by: thread, in: app)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let third = sight.height / 3
        return (
            origin.withOffset(CGVector(dx: sight.midX, dy: sight.minY + third)),
            origin.withOffset(CGVector(dx: sight.midX, dy: sight.maxY - third / 2))
        )
    }

    /// The cost the app logged for the fling just made, once it has stopped: its newest
    /// "fling" line, once that is not `previous`. Empty when none came.
    private func nextFlingCost(after previous: String?, in app: XCUIApplication) -> String {
        let log = app.descendants(matching: .any)["debug.threadLog"]
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let newest = log.label.components(separatedBy: " | ").last { $0.hasPrefix("fling built") }
            if let newest, newest != previous {
                return newest
            }
            settle(0.5)
        }
        return ""
    }

    /// The label and top of the message nearest the middle of the thread.
    private func readMessage(in thread: XCUIElement) throws -> (label: String, minY: CGFloat) {
        let middle = thread.frame.midY
        let messages = try Self.messages(in: thread.snapshot())
        let nearest = try XCTUnwrap(messages.min { abs($0.frame.midY - middle) < abs($1.frame.midY - middle) }, "no message on screen")
        return (nearest.label, nearest.frame.minY)
    }

    /// Fails when a message on screen is drawn over the next one down. Each is read from one
    /// snapshot of the thread, so all of them at the same moment. A message's element reads
    /// up to 17 points above its bubble, where a reaction lands (ui-test frames), so up to 20
    /// points of meeting is no overlap.
    private func assertNoMessageOverAnother(in thread: XCUIElement, _ moment: String) throws {
        let frames = try Self.messages(in: thread.snapshot()).map(\.frame).sorted { $0.minY < $1.minY }
        for (upper, lower) in zip(frames, frames.dropFirst()) {
            XCTAssertLessThanOrEqual(upper.maxY - lower.minY, 20, "\(moment), a message at \(upper) is drawn over the one at \(lower)")
        }
    }

    private static func messages(in snapshot: XCUIElementSnapshot) -> [XCUIElementSnapshot] {
        let own = snapshot.identifier == "room.message" && snapshot.frame.height > 0 ? [snapshot] : []
        return own + snapshot.children.flatMap { messages(in: $0) }
    }

    private func settle(_ seconds: TimeInterval) {
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "the screen settles")], timeout: seconds)
    }
}
