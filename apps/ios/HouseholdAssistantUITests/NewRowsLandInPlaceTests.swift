// Whatever joins the bottom of Corey's thread lands in place (CFO notes section 21b): his own
// voice note as he sends it, Corey's typing dots, a reply streaming in, a calendar card and a
// photo whose shape comes only with its picture. At the newest message each comes to rest
// just above the composer, is never under the composer while it arrives, and keeps its
// bottom edge as it grows. Scrolled up to read, the message being read does not move, the
// new row stays below, and the control to jump to the newest shows and goes there. His own
// voice note brings the thread to it from wherever he was, as anything he sends does. The
// demo adds each row on the test's cue (DemoGateway).

import XCTest

// On the main actor, where XCUIApplication and every query live.
@MainActor
final class NewRowsLandInPlaceTests: XCTestCase {
    /// The rows the demo adds on a cue, and his own voice note, which he sends himself.
    private enum NewRow: String {
        case typing
        case stream
        case card
        case photo
        case voiceNote

        /// What the row's bubble says, or, for a card with buttons of its own, which VoiceOver
        /// reads as a container, what something inside it says.
        var predicate: NSPredicate {
            switch self {
            case .typing:
                NSPredicate(format: "label CONTAINS %@", "is typing")
            case .stream:
                NSPredicate(format: "label CONTAINS %@", "Here is the day.")
            case .card:
                NSPredicate(format: "label BEGINSWITH %@", "Dinner at home")
            case .photo:
                NSPredicate(format: "label CONTAINS %@", "Photo")
            case .voiceNote:
                NSPredicate(format: "label CONTAINS[c] %@", "voice note")
            }
        }

        /// How far the room between the row and the composer may change while it lands. A
        /// row of his own rises once by the "Delivered" under it, as in Messages.
        var allowedShift: CGFloat {
            self == .voiceNote ? 24 : 2
        }

        /// How far above the composer the bubble comes to rest: a card's has the chip saying
        /// what Corey put on the calendar under it.
        var restsWithin: CGFloat {
            self == .card ? 140 : 80
        }
    }

    /// The thread open on screen, and how the test speaks to the demo.
    private struct OpenThread {
        let app: XCUIApplication
        let control: String

        /// What the thread's list logged last, for a failure to say how it moved (ThreadLog).
        var log: String {
            app.descendants(matching: .any)["debug.threadLog"].label
        }
        let list: XCUIElement
        let field: XCUIElement
        let messages: XCUIElementQuery

        /// The new row's bubble, from the moment it shows.
        func row(_ kind: NewRow) -> XCUIElement {
            switch kind {
            case .typing:
                app.descendants(matching: .any).matching(kind.predicate).firstMatch
            case .card:
                messages.containing(kind.predicate).firstMatch
            case .stream, .photo, .voiceNote:
                messages.matching(kind.predicate).firstMatch
            }
        }
    }

    /// Long enough for the longest arrival, the streamed reply, to finish and settle.
    private static let arriving: TimeInterval = 6

    nonisolated override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testTypingLandsAboveTheComposer() throws {
        try landsAtTheNewest(.typing)
    }

    func testStreamingReplyLandsAboveTheComposer() throws {
        try landsAtTheNewest(.stream)
    }

    func testCardLandsAboveTheComposer() throws {
        try landsAtTheNewest(.card)
    }

    func testLatePhotoLandsAboveTheComposer() throws {
        try landsAtTheNewest(.photo)
    }

    func testVoiceNoteLandsAboveTheComposer() throws {
        try landsAtTheNewest(.voiceNote)
    }

    func testTypingLeavesTheReaderWhereTheyRead() throws {
        try leavesTheReader(.typing)
    }

    func testStreamingReplyLeavesTheReaderWhereTheyRead() throws {
        try leavesTheReader(.stream)
    }

    func testCardLeavesTheReaderWhereTheyRead() throws {
        try leavesTheReader(.card)
    }

    func testLatePhotoLeavesTheReaderWhereTheyRead() throws {
        try leavesTheReader(.photo)
    }

    func testVoiceNoteSentWhileReadingBringsTheThreadToIt() throws {
        // Arrange
        let thread = openCoreysThread()
        _ = try scrollUpToRead(in: thread)

        // Act
        try VoiceNoteRecording.lockedNote(in: thread.app).tap()

        // Assert
        let note = thread.row(.voiceNote)
        XCTAssertTrue(note.waitForExistence(timeout: 10), "the voice note never showed")
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: note)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed, "the thread did not come to the voice note")
        Thread.sleep(forTimeInterval: 1)
        let gap = thread.field.frame.minY - note.frame.maxY
        XCTAssertGreaterThanOrEqual(gap, -1, "the composer covers the voice note")
        XCTAssertLessThan(gap, 80, "the voice note came to rest far above the composer")
    }

    // MARK: - The way each is checked

    private func landsAtTheNewest(_ kind: NewRow) throws {
        // Arrange
        let thread = openCoreysThread()
        let done = kind == .voiceNote ? nil : XCTDarwinNotificationExpectation(notificationName: thread.control + "." + kind.rawValue + ".done")

        // Act
        if let done {
            cue(kind, in: thread)
            let gaps = roomUnder(thread.row(kind), above: thread.field, for: Self.arriving)
            XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 10), .completed, "the demo never finished adding the row")

            // Assert
            try assertLanded(gaps, kind, in: thread)
        } else {
            try VoiceNoteRecording.lockedNote(in: thread.app).tap()
            let gaps = roomUnder(thread.row(kind), above: thread.field, for: Self.arriving)

            // Assert
            try assertLanded(gaps, kind, in: thread)
        }
    }

    /// The row came to rest just above the composer, never went under it and never moved.
    private func assertLanded(_ gaps: [CGFloat], _ kind: NewRow, in thread: OpenThread) throws {
        let rest = try XCTUnwrap(gaps.last, "the new row never showed. \(thread.log)")
        XCTAssertGreaterThanOrEqual(gaps.min() ?? 0, -1, "the new row went under the composer while it arrived: \(gaps). \(thread.log)")
        XCTAssertLessThan(rest, kind.restsWithin, "the new row came to rest far above the composer: \(gaps). \(thread.log)")
        XCTAssertLessThanOrEqual(
            (gaps.max() ?? 0) - (gaps.min() ?? 0), kind.allowedShift, "the new row moved while it landed: \(gaps). \(thread.log)"
        )
    }

    private func leavesTheReader(_ kind: NewRow) throws {
        // Arrange
        let thread = openCoreysThread()
        let reading = try scrollUpToRead(in: thread)
        let before = try reading.snapshot().frame
        let done = XCTDarwinNotificationExpectation(notificationName: thread.control + "." + kind.rawValue + ".done")

        // Act
        cue(kind, in: thread)
        var tops: [CGFloat] = []
        let end = Date().addingTimeInterval(Self.arriving)
        while Date() < end {
            if let frame = try? reading.snapshot().frame {
                tops.append(frame.minY)
            }
        }
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 10), .completed, "the demo never finished adding the row")

        // Assert
        let moved = tops.map { abs($0 - before.minY) }.max() ?? .infinity
        XCTAssertLessThanOrEqual(
            moved, 1, "the message being read moved while the new row arrived: \(tops) from \(before.minY). \(thread.log)"
        )
        let row = thread.row(kind)
        XCTAssertFalse(row.exists && row.isHittable, "the new row pulled the reader down to it")
        let jump = thread.app.buttons["thread.jumpToNewest"]
        XCTAssertTrue(jump.waitForExistence(timeout: 3) && jump.isHittable, "no control to jump to the newest")
        jump.tap()
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND isHittable == true"), object: row)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 5), .completed, "jumping to the newest did not show the new row. \(thread.log)")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertGreaterThanOrEqual(thread.field.frame.minY - row.frame.maxY, -1, "the composer covers the new row")
    }

    // MARK: - The way there

    private func openCoreysThread() -> OpenThread {
        let app = XCUIApplication()
        let control = "steward-new-rows-" + UUID().uuidString
        app.launchArguments = ["-StewardDemo", "YES", "-StewardNewRowsControl", control, "-StewardThreadLog", "YES"]
        app.launch()
        let pin = app.buttons["pin.direct"]
        XCTAssertTrue(pin.waitForExistence(timeout: 30), "Chats never showed")
        pin.tap()
        let list = app.collectionViews["room.thread"]
        XCTAssertTrue(list.waitForExistence(timeout: 10), "the thread never showed")
        let field = app.descendants(matching: .any).matching(identifier: "composer.field").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the message field is missing")
        // The thread settles at its newest before anything joins it.
        Thread.sleep(forTimeInterval: 1)
        return OpenThread(
            app: app,
            control: control,
            list: list,
            field: field,
            messages: list.descendants(matching: .any).matching(identifier: "room.message")
        )
    }

    private func cue(_ kind: NewRow, in thread: OpenThread) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName((thread.control + "." + kind.rawValue) as CFString), nil, nil, true
        )
    }

    /// The room between the row's bottom edge and the top of the message field, each time
    /// both are read while the row lands. Negative is under the composer.
    private func roomUnder(_ row: XCUIElement, above field: XCUIElement, for seconds: TimeInterval) -> [CGFloat] {
        var gaps: [CGFloat] = []
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let frame = try? row.snapshot().frame, let fieldFrame = try? field.snapshot().frame {
                gaps.append(fieldFrame.minY - frame.maxY)
            }
        }
        return gaps
    }

    /// Drags the thread down slowly, as a finger reading back does, and hands back a message
    /// wholly on screen that no other built row repeats, with the newest out of sight.
    private func scrollUpToRead(in thread: OpenThread) throws -> XCUIElement {
        let start = thread.list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let end = thread.list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        for _ in 0..<3 {
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        let visibleTop = max(thread.list.frame.minY, thread.app.navigationBars.firstMatch.frame.maxY)
        let fieldTop = thread.field.frame.minY
        let found = thread.messages.allElementsBoundByIndex.lazy.compactMap { message -> XCUIElement? in
            guard let shown = try? message.snapshot(), shown.frame.minY >= visibleTop, shown.frame.maxY <= fieldTop, shown.frame.height > 30 else {
                return nil
            }
            let same = thread.messages.matching(NSPredicate(format: "label == %@", shown.label))
            return same.count == 1 ? same.firstMatch : nil
        }.first
        return try XCTUnwrap(found, "no message on screen to read that no other row repeats")
    }
}
