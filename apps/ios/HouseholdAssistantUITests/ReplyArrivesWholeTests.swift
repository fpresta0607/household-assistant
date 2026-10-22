// Corey's reply shows whole once it is complete, never typed out word by word. While it
// streams in, his typing row stands in for it and no part of it shows; once it is in, all
// of it shows at once. One taller than the thread lands with its top at the top of what
// shows, so it is read from the start, and the thread does not follow it down to its end.
// The demo streams each reply in on the test's cue (DemoGateway).
//
// The demo dates its scene at set times of day, Corey's last message at 14:50, so before
// then a reply stamped now comes before it by the clock: no time sits over the reply and it
// joins his run. A message's element reads about 17 points higher than it is drawn, where a
// reaction lands (ui-test frames). Under a time that falls on the time; with none, on night
// runs, the long reply read 12 points above the thread although it was drawn just below it.
// Each test here runs the demo's clock from five in the afternoon, so it reads the same at
// any hour, and one lands the long reply at two in the morning and at five in the afternoon
// and finds its row starting where Corey's message ends, at the top of the thread, both times
// (CFO notes section 6).

import XCTest

// On the main actor, where XCUIApplication and every query live.
@MainActor
final class ReplyArrivesWholeTests: XCTestCase {
    /// What the screen showed of the reply each time the test looked while it arrived.
    private struct Sample {
        let isTyping: Bool
        /// The reply's words when some of it showed.
        let shown: String?
    }

    /// The thread open on screen, and how the test speaks to the demo.
    private struct OpenThread {
        let app: XCUIApplication
        let control: String
        let list: XCUIElement
        let field: XCUIElement

        /// What the thread's list logged last, for a failure to say how it moved (ThreadLog).
        var log: String {
            app.descendants(matching: .any)["debug.threadLog"].label
        }

        /// The top of the part of the thread no bar covers.
        var visibleTop: CGFloat {
            max(list.frame.minY, app.navigationBars.firstMatch.frame.maxY)
        }

        /// The message whose words start with `opening`.
        func message(opening: String) -> XCUIElement {
            list.descendants(matching: .any).matching(identifier: "room.message")
                .matching(NSPredicate(format: "label CONTAINS %@", opening)).firstMatch
        }
    }

    /// When the demo's clock starts for every test but the one that compares two hours: past
    /// every time the scene is dated at today.
    private static let afternoon = "17:00"

    nonisolated override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testALongReplyShowsWholeWithItsTopAtTheTop() throws {
        // Arrange
        let thread = openCoreysThread()
        // Without its apostrophe, which the reply draws curled.
        let reply = thread.message(opening: "Here is this morning")

        // Act
        let samples = watch(reply, until: "That is the whole reading for today.", cue: "longReply", in: thread)

        // Assert
        try assertArrivedWhole(samples, ending: "That is the whole reading for today.", in: thread)
        let landed = try reply.snapshot().frame
        XCTAssertGreaterThanOrEqual(landed.minY, thread.visibleTop - 1, "the reply's top is above the thread. \(thread.log)")
        XCTAssertLessThan(landed.minY, thread.visibleTop + 60, "the reply's top is not at the top of the thread. \(thread.log)")
        XCTAssertGreaterThan(landed.maxY, thread.field.frame.minY, "the thread followed the reply down to its end. \(thread.log)")
        Thread.sleep(forTimeInterval: 0.5)
        let settled = try reply.snapshot().frame
        XCTAssertEqual(settled.minY, landed.minY, accuracy: 1, "the reply moved after it landed. \(thread.log)")
        XCTAssertEqual(settled.height, landed.height, accuracy: 0.5, "the reply grew after it landed. \(thread.log)")
    }

    func testAShortReplyShowsWholeAboveTheComposer() throws {
        // Arrange
        let thread = openCoreysThread()
        let reply = thread.message(opening: "Here is the day.")

        // Act
        let samples = watch(reply, until: "That is the whole plan for today.", cue: "stream", in: thread)

        // Assert
        try assertArrivedWhole(samples, ending: "That is the whole plan for today.", in: thread)
        let landed = try reply.snapshot().frame
        XCTAssertGreaterThanOrEqual(landed.minY, thread.visibleTop - 1, "the reply's top is above the thread. \(thread.log)")
        XCTAssertGreaterThanOrEqual(thread.field.frame.minY - landed.maxY, -1, "the composer covers the reply. \(thread.log)")
        XCTAssertLessThan(thread.field.frame.minY - landed.maxY, 80, "the reply came to rest far above the composer. \(thread.log)")
    }

    func testTheLongReplyLandsAtTheTopAtTwoInTheMorningAndAtFiveInTheAfternoon() throws {
        for clock in ["02:00", Self.afternoon] {
            // Arrange
            let thread = openCoreysThread(at: clock)
            let reply = thread.message(opening: "Here is this morning")

            // Act
            _ = watch(reply, until: "That is the whole reading for today.", cue: "longReply", in: thread)

            // Assert
            let landed = try reply.snapshot().frame
            // A message's bottom edge reads true, so the row above the reply ends where the
            // reply's row starts. The reply's element reads over its time, so the time is
            // looked for anywhere between that row and the reply's bottom.
            let above = try thread.message(opening: "needs a signature by Friday").snapshot().frame
            let time = thread.app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Today")).allElementsBoundByIndex
                .map(\.frame)
                .first { $0.minY >= above.maxY - 1 && $0.maxY <= landed.maxY }
            print(
                "At \(clock): the message above ends at \(above.maxY), the thread's top is \(thread.visibleTop), "
                    + "the reply's element starts at \(landed.minY), \(time.map { "a time over it at \($0.minY)" } ?? "no time over it")"
            )
            XCTAssertEqual(above.maxY, thread.visibleTop, accuracy: 2, "at \(clock) the reply's row does not start at the top of the thread. \(thread.log)")
            if clock == Self.afternoon {
                XCTAssertNotNil(time, "at \(clock) no time sits over the reply, though over an hour has passed since the message above it")
            } else {
                XCTAssertNil(time, "at \(clock) a time sits over the reply, which comes before the message above it by the clock")
            }
            thread.app.terminate()
        }
    }

    // MARK: - The way each is checked

    /// Cues the reply and looks at the screen until it has shown with `ending` for a moment.
    private func watch(_ reply: XCUIElement, until ending: String, cue: String, in thread: OpenThread) -> [Sample] {
        let typing = thread.app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "is typing")).firstMatch
        let done = XCTDarwinNotificationExpectation(notificationName: thread.control + "." + cue + ".done")
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName((thread.control + "." + cue) as CFString), nil, nil, true
        )
        var samples: [Sample] = []
        var wholeAt: Date?
        let end = Date().addingTimeInterval(20)
        while Date() < end, Date() < (wholeAt ?? end).addingTimeInterval(1.5) {
            let shown = (try? reply.snapshot())?.label
            samples.append(Sample(isTyping: typing.exists, shown: shown))
            if wholeAt == nil, shown?.contains(ending) == true {
                wholeAt = Date()
            }
        }
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 10), .completed, "the demo never finished the reply")
        return samples
    }

    /// No part of the reply showed before all of it did, and the typing row stood in for it
    /// until then.
    private func assertArrivedWhole(_ samples: [Sample], ending: String, in thread: OpenThread) throws {
        let partial = samples.compactMap(\.shown).filter { !$0.contains(ending) }
        XCTAssertTrue(partial.isEmpty, "the reply showed before it was complete: \(partial.prefix(3)). \(thread.log)")
        let whole = try XCTUnwrap(samples.firstIndex { $0.shown != nil }, "the reply never showed. \(thread.log)")
        let typingFrom = try XCTUnwrap(samples.firstIndex(where: \.isTyping), "Corey's typing row never showed. \(thread.log)")
        XCTAssertLessThan(typingFrom, whole, "the reply showed before Corey's typing row. \(thread.log)")
        let gaps = samples[typingFrom..<whole].filter { !$0.isTyping }.count
        XCTAssertEqual(gaps, 0, "the typing row went away \(gaps) times before the reply showed. \(thread.log)")
    }

    // MARK: - The way there

    /// Corey's thread with the demo's clock started at `clock`, a time of day.
    private func openCoreysThread(at clock: String = ReplyArrivesWholeTests.afternoon) -> OpenThread {
        let app = XCUIApplication()
        let control = "steward-reply-whole-" + UUID().uuidString
        app.launchArguments = [
            "-StewardDemo", "YES", "-StewardNewRowsControl", control, "-StewardThreadLog", "YES", "-StewardDemoClock", clock,
        ]
        app.launch()
        let pin = app.buttons["pin.direct"]
        XCTAssertTrue(pin.waitForExistence(timeout: 30), "Chats never showed")
        pin.tap()
        let list = app.collectionViews["room.thread"]
        XCTAssertTrue(list.waitForExistence(timeout: 10), "the thread never showed")
        let field = app.descendants(matching: .any).matching(identifier: "composer.field").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the message field is missing")
        // The thread settles at its newest before Corey answers.
        Thread.sleep(forTimeInterval: 1)
        return OpenThread(app: app, control: control, list: list, field: field)
    }
}
