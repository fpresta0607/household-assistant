import UIKit
import Vision
import XCTest

@MainActor
final class MessageActionsTests: XCTestCase {
    nonisolated override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testHorizontalSwipesLeaveMessagesStillAndTimesAreInTheMenu() {
        let app = XCUIApplication()
        let control = "steward-timestamp-fix-" + UUID().uuidString
        app.launchArguments = ["-StewardDemo", "YES", "-StewardMessageActionsDemo", "YES",
                               "-StewardMessageActionsControl", control, "-StewardThreadLog", "YES"]
        app.launch()
        for conversation in ["direct", "family"] {
            let pin = app.buttons["pin.\(conversation)"]
            XCTAssertTrue(pin.waitForExistence(timeout: 30))
            pin.tap()
            let thread = app.collectionViews["room.thread"]
            XCTAssertTrue(thread.waitForExistence(timeout: 10))
            let field = app.descendants(matching: .any).matching(identifier: "composer.field").firstMatch
            let messages = thread.descendants(matching: .any).matching(identifier: "room.message")
            let question = messages.matching(NSPredicate(format: "label CONTAINS %@", "Please bring the garden notebook.")).firstMatch
            let reply = messages.matching(NSPredicate(format: "label CONTAINS %@", "I will bring the garden notebook.")).firstMatch
            let newest = messages.matching(NSPredicate(format: "label CONTAINS %@", "Everything is ready for the walk.")).firstMatch
            XCTAssertTrue(newest.waitForExistence(timeout: 10))
            for _ in 0..<2 {
                verifyMessageTimes(in: app, thread: thread, field: field,
                                     rows: [question, reply, newest], control: control)
            }
            if conversation == "direct" {
                field.tap()
                XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
                verifyMessageTimes(in: app, thread: thread, field: field, rows: [reply, newest], control: control)
                XCTAssertTrue(app.keyboards.firstMatch.exists)
            }
            let y = newest.frame.minY
            let hadKeyboard = app.keyboards.firstMatch.exists
            let start = newest.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -20, dy: 160)),
                        withVelocity: .slow, thenHoldForDuration: 0.1)
            XCTAssertTrue(!newest.isHittable || abs(newest.frame.minY - y) > 30 || (hadKeyboard && !app.keyboards.firstMatch.exists))
            XCTAssertFalse(timestampLabels(in: app).firstMatch.exists)
            XCTAssertFalse(app.buttons["Reply"].exists)
            XCTAssertFalse(app.buttons["Share the chat"].exists)
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
    }

    func testTableScrollsHorizontallyWithoutMovingItsMessage() {
        let app = openMediaDemo()
        let table = app.scrollViews["card.table-scroll"]
        XCTAssertTrue(table.waitForExistence(timeout: 10))
        let title = app.staticTexts["Pocket Piggies spending"]
        let frame = title.frame
        let firstColumn = app.staticTexts["Garden Market"]
        let firstColumnX = firstColumn.frame.minX
        let start = table.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -200, dy: 0)),
                    withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertEqual(title.frame.minX, frame.minX, accuracy: 1)
        XCTAssertEqual(title.frame.minY, frame.minY, accuracy: 1)
        XCTAssertLessThan(firstColumn.frame.minX, firstColumnX - 30, "the cells must scroll inside the bubble")
        let finalColumn = app.staticTexts["$257.82"]
        for _ in 0..<3 where !finalColumn.isHittable { table.swipeLeft() }
        XCTAssertTrue(finalColumn.isHittable, "the table must reveal its last column")
        XCTAssertFalse(timestampLabels(in: app).firstMatch.exists)
        XCTAssertFalse(app.buttons["Reply"].exists)
    }

    func testExpandedTranscriptCopiesIntoTheComposer() {
        let app = openMediaDemo()
        let note = app.descendants(matching: .any).matching(identifier: "room.message")
            .matching(NSPredicate(format: "label CONTAINS %@", "Voice note")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 10))
        note.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5)).tap()
        let disclosure = app.buttons["Show the transcript"]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        disclosure.tap()
        let copy = app.buttons["voice-note.copy-transcript"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        copy.tap()
        let field = app.descendants(matching: .any).matching(identifier: "composer.field").firstMatch
        field.tap()
        field.press(forDuration: 0.8)
        let paste = app.menuItems["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        paste.tap()
        let pasted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Come home soon, the pasta is getting cold."), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [pasted], timeout: 5), .completed)
    }

    private func openMediaDemo() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-StewardDemo", "YES", "-StewardMessageActionsDemo", "YES", "-StewardMessageMediaDemo", "YES"]
        app.launch()
        let pin = app.buttons["pin.family"]
        XCTAssertTrue(pin.waitForExistence(timeout: 30))
        pin.tap()
        XCTAssertTrue(app.collectionViews["room.thread"].waitForExistence(timeout: 10))
        return app
    }

    func testSelectTextCopiesOnlyThePassageAndWholeMessageCopyStillWorks() {
        let app = XCUIApplication()
        app.launchArguments = ["-StewardDemo", "YES", "-StewardMessageActionsDemo", "YES"]
        app.launch()
        let pin = app.buttons["pin.direct"]
        XCTAssertTrue(pin.waitForExistence(timeout: 30))
        pin.tap()
        let thread = app.collectionViews["room.thread"]
        XCTAssertTrue(thread.waitForExistence(timeout: 10))
        let message = thread.descendants(matching: .any).matching(identifier: "room.message")
            .matching(NSPredicate(format: "label CONTAINS %@", "Everything is ready for the walk.")).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        message.press(forDuration: 0.6)
        XCTAssertTrue(app.buttons["Select Text"].waitForExistence(timeout: 5))
        app.buttons["Select Text"].tap()
        let selection = app.textViews["message.selectable-text"]
        XCTAssertTrue(selection.waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars.staticTexts["Select Text"].exists)
        let copy = app.buttons["message.copy-selection"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        XCTAssertTrue(copy.isEnabled)
        copy.tap()
        let field = app.descendants(matching: .any).matching(identifier: "composer.field").firstMatch
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        field.press(forDuration: 0.8)
        XCTAssertTrue(app.menuItems["Paste"].waitForExistence(timeout: 5))
        app.menuItems["Paste"].tap()
        let partial = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Everything"), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [partial], timeout: 5), .completed)
        XCTAssertTrue(message.label.contains("Everything is ready for the walk."))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(pin.waitForExistence(timeout: 5))
        pin.tap()
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        message.press(forDuration: 0.6)
        XCTAssertTrue(app.buttons["Copy"].waitForExistence(timeout: 5))
        app.buttons["Copy"].tap()
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        field.press(forDuration: 0.8)
        XCTAssertTrue(app.menuItems["Paste"].waitForExistence(timeout: 5))
        app.menuItems["Paste"].tap()
        let whole = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Everything is ready for the walk."), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [whole], timeout: 5), .completed)
    }

    func testSpeakReadsTheSelectedMessageAndCanBeStoppedWithoutPostingAReply() {
        let app = XCUIApplication()
        app.launchArguments = ["-StewardDemo", "YES", "-StewardMessageActionsDemo", "YES", "-StewardMessageSpeechDemo", "YES"]
        app.launch()
        let pin = app.buttons["pin.direct"]
        XCTAssertTrue(pin.waitForExistence(timeout: 30))
        pin.tap()
        let thread = app.collectionViews["room.thread"]
        XCTAssertTrue(thread.waitForExistence(timeout: 10))
        let message = thread.descendants(matching: .any).matching(identifier: "room.message")
            .matching(NSPredicate(format: "label CONTAINS %@", "Everything is ready for the walk.")).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        message.press(forDuration: 0.6)
        let speak = app.buttons["message.speak"]
        XCTAssertTrue(speak.waitForExistence(timeout: 5))
        XCTAssertEqual(speak.label, "Speak")
        speak.tap()
        let stop = app.buttons["message.stop-speaking"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Corey is speaking"].waitForExistence(timeout: 10))
        message.press(forDuration: 0.6)
        XCTAssertTrue(speak.waitForExistence(timeout: 5))
        XCTAssertEqual(speak.label, "Stop Speaking")
        speak.tap()
        XCTAssertTrue(stop.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Corey is speaking"].exists)
        XCTAssertTrue(message.isHittable)
        XCTAssertFalse(thread.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Spoken as")).firstMatch.exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "message-speech-stopped"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testLongMessagesActionsAndMenuTimestamps() throws {
        for isHuman in [false, true] {
            let app = XCUIApplication()
            let control = "steward-message-actions-" + UUID().uuidString
            app.launchArguments = [
                "-StewardDemo", "YES", "-StewardMessageActionsDemo", "YES",
                "-StewardMessageActionsHuman", isHuman ? "YES" : "NO",
                "-StewardMessageActionsControl", control,
                "-StewardThreadLog", "YES",
            ]
            app.launch()
            for conversation in ["direct", "family"] {
                let pin = app.buttons["pin.\(conversation)"]
                XCTAssertTrue(pin.waitForExistence(timeout: 30))
                pin.tap()
                let thread = app.collectionViews["room.thread"]
                XCTAssertTrue(thread.waitForExistence(timeout: 10))
                let field = app.descendants(matching: .any).matching(identifier: "composer.field").firstMatch
                XCTAssertTrue(field.waitForExistence(timeout: 5))
                let messages = thread.descendants(matching: .any).matching(identifier: "room.message")
                let question = messages.matching(NSPredicate(format: "label CONTAINS %@", "Please bring the garden notebook.")).firstMatch
                let reply = messages.matching(NSPredicate(format: "label CONTAINS %@", "I will bring the garden notebook.")).firstMatch
                let newestText = "Everything is ready for the walk."
                let newest = messages.matching(NSPredicate(format: "label CONTAINS %@", newestText)).firstMatch
                XCTAssertTrue(question.waitForExistence(timeout: 10) && question.isHittable)
                XCTAssertTrue(reply.waitForExistence(timeout: 5) && reply.isHittable)
                let reaction = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Corey liked this")).firstMatch
                XCTAssertTrue(reaction.waitForExistence(timeout: 5) && reaction.isHittable)
                XCTAssertLessThan(abs(reaction.frame.midY - question.frame.minY), 45)
                XCTAssertFalse(app.keyboards.firstMatch.exists)

                if !isHuman && conversation == "direct" {
                    field.tap()
                    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
                    try verifyRenderedText(newestText, in: app, field: field,
                                           named: "actions-assistant-direct-keyboard-before-menu")
                    XCTAssertTrue(reply.isHittable)
                    let dismissStart = reply.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                    let dismissEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
                    dismissStart.press(forDuration: 0.05, thenDragTo: dismissEnd,
                                       withVelocity: .slow, thenHoldForDuration: 0.1)
                    let dismissed = XCTNSPredicateExpectation(
                        predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch
                    )
                    XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed,
                                   "a vertical drag must dismiss the keyboard before the message actions")
                    app.terminate()
                    app.launch()
                    XCTAssertTrue(pin.waitForExistence(timeout: 30))
                    pin.tap()
                    XCTAssertTrue(newest.waitForExistence(timeout: 10))
                    XCTAssertFalse(app.keyboards.firstMatch.exists)
                }

                verifyMessageTimes(in: app, thread: thread, field: field, rows: [question, reply, newest], control: control)

                let beforeScroll = question.frame
                let start = thread.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 180)), withVelocity: .slow, thenHoldForDuration: 0.1)
                XCTAssertTrue(!question.isHittable || abs(question.frame.minY - beforeScroll.minY) > 30,
                              "a vertical drag must still scroll the conversation")
                XCTAssertFalse(timestampLabels(in: app).firstMatch.exists)
                XCTAssertFalse(app.buttons["Cancel reply"].exists)

                app.navigationBars.buttons.element(boundBy: 0).tap()
                XCTAssertTrue(pin.waitForExistence(timeout: 5))
                pin.tap()
                XCTAssertTrue(newest.waitForExistence(timeout: 10))

                let kind = isHuman ? "human" : "assistant"
                let final = "Final paragraph for \(kind) e2b61. The complete message ends here."
                let longMessage = messages.matching(NSPredicate(format: "label CONTAINS %@", final)).firstMatch
                revealEnd(of: longMessage, in: app, thread: thread, field: field)
                keepScreenshot(app, named: "actions-\(kind)-\(conversation)-final-paragraph")

                // Press the words on the last line, inside the paragraph, rather than the bubble's padding.
                let textPoint = app.coordinate(withNormalizedOffset: .zero).withOffset(
                    CGVector(dx: longMessage.frame.minX + 26, dy: longMessage.frame.maxY - 23)
                )
                textPoint.press(forDuration: 0.7)
                XCTAssertTrue(app.buttons["Reply"].waitForExistence(timeout: 5), "long-pressing actual text did not open the message menu")
                XCTAssertTrue(app.buttons["Copy"].exists)
                XCTAssertTrue(app.buttons["Thumbs up"].exists)
                XCTAssertFalse(app.menuItems["Select more text"].exists)
                keepScreenshot(app, named: "actions-\(kind)-\(conversation)-menu")
                app.buttons["Copy"].tap()

                field.tap()
                let hasKeyboard = app.keyboards.firstMatch.waitForExistence(timeout: 5)
                let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch
                XCTAssertTrue(
                    hasKeyboard,
                    "no keyboard after Copy, focus on \(focused.exists ? "\(focused.elementType.rawValue) \(focused.identifier)" : "nothing"), "
                        + "menus \(app.menuItems.allElementsBoundByIndex.map(\.label)). "
                        + app.descendants(matching: .any)["debug.threadLog"].label
                )
                try verifyRenderedText(newestText, in: app, field: field,
                                       named: "actions-\(kind)-\(conversation)-keyboard-after-copy")
                let emptyComposerHeight = field.frame.height
                field.press(forDuration: 0.8)
                let paste = app.menuItems["Paste"]
                XCTAssertTrue(paste.waitForExistence(timeout: 5))
                paste.tap()
                let expected = (1...64).map { index in
                    "Paragraph \(index): " + (isHuman ? "Every detail belongs here." : "**Every detail belongs here.**")
                        + " We are keeping the complete account of the garden, the library, the school visit and the evening walk, including the final words. 🏡"
                }.joined(separator: "\n\n") + "\n\n" + final
                XCTAssertGreaterThan(expected.utf16.count, 8_000)
                let copied = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: field)
                XCTAssertEqual(XCTWaiter.wait(for: [copied], timeout: 5), .completed,
                               "Copy must paste every paragraph and omit the internal followup card")
                let visibleAfterPaste = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    // A blank conversation must fail this, not throw on its missing rows.
                    guard field.frame.height > emptyComposerHeight, newest.exists, newest.isHittable else {
                        return false
                    }
                    let top = app.navigationBars.firstMatch.frame.maxY
                    let bottom = field.frame.minY - 12
                    return thread.frame.contains(newest.frame)
                        && newest.frame.minY >= top && newest.frame.maxY <= bottom
                }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [visibleAfterPaste], timeout: 5), .completed,
                               "expanding the composer with a copied message must keep the newest row fully visible")
                try verifyRenderedText(newestText, in: app, field: field,
                                       named: "actions-\(kind)-\(conversation)-pasted-draft")

                app.navigationBars.buttons.element(boundBy: 0).tap()
                XCTAssertTrue(pin.waitForExistence(timeout: 5))
                pin.tap()
                XCTAssertTrue(newest.waitForExistence(timeout: 10))
                XCTAssertTrue(app.buttons["Take a photo or video"].waitForExistence(timeout: 5),
                              "reopening the conversation must restore the empty composer")
                revealEnd(of: longMessage, in: app, thread: thread, field: field)
                keepScreenshot(app, named: "actions-\(kind)-\(conversation)-reopened-final")
                let reopenedPoint = app.coordinate(withNormalizedOffset: .zero).withOffset(
                    CGVector(dx: longMessage.frame.minX + 26, dy: longMessage.frame.maxY - 23)
                )
                reopenedPoint.press(forDuration: 0.7)
                XCTAssertTrue(app.buttons["Reply"].waitForExistence(timeout: 5))
                app.buttons["Reply"].tap()
                XCTAssertTrue(app.buttons["Cancel reply"].waitForExistence(timeout: 5))
                app.buttons["Cancel reply"].tap()
                let replyCancelled = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "exists == false"), object: app.buttons["Cancel reply"]
                )
                XCTAssertEqual(XCTWaiter.wait(for: [replyCancelled], timeout: 5), .completed,
                               "Cancel reply must remove the reply strip before opening the keyboard")
                field.tap()
                XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
                for _ in 0..<5 {
                    if [reply, newest].allSatisfy({
                        $0.isHittable && $0.frame.minY >= app.navigationBars.firstMatch.frame.maxY
                            && $0.frame.maxY <= field.frame.minY - 24
                    }) { break }
                    thread.swipeUp(velocity: .fast)
                }
                verifyMessageTimes(in: app, thread: thread, field: field, rows: [reply, newest], control: control)
                XCTAssertTrue(app.keyboards.firstMatch.exists)
                let dismissStart = reply.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                let dismissEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
                dismissStart.press(forDuration: 0.05, thenDragTo: dismissEnd,
                                   withVelocity: .slow, thenHoldForDuration: 0.1)
                let dismissed = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch
                )
                XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed,
                               "a vertical drag must dismiss the shown keyboard")
                XCTAssertFalse(timestampLabels(in: app).firstMatch.exists)
                XCTAssertFalse(app.buttons["Cancel reply"].exists)
                app.navigationBars.buttons.element(boundBy: 0).tap()
            }
            app.terminate()
        }
    }

    private func verifyMessageTimes(
        in app: XCUIApplication, thread: XCUIElement, field: XCUIElement,
        rows: [XCUIElement], control: String
    ) {
        XCTAssertFalse(timestampLabels(in: app).firstMatch.exists)
        let top = max(thread.frame.minY, app.navigationBars.firstMatch.frame.maxY)
        let bottom = min(thread.frame.maxY, field.frame.minY - 24)
        let frames = rows.map { row in
            XCTAssertTrue(row.isHittable)
            XCTAssertGreaterThanOrEqual(row.frame.minY, top, "the navigation bar must not cover the selected row")
            XCTAssertLessThanOrEqual(row.frame.maxY, bottom, "the composer must not cover the selected row or timestamp")
            return row.frame
        }
        let start = rows[rows.count - 1].coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -125, dy: 0)),
                    withVelocity: .slow, thenHoldForDuration: 0.1)
        for (row, frame) in zip(rows, frames) {
            XCTAssertEqual(row.frame.minX, frame.minX, accuracy: 1,
                           app.descendants(matching: .any)["debug.threadLog"].label)
            XCTAssertEqual(row.frame.minY, frame.minY, accuracy: 1,
                           app.descendants(matching: .any)["debug.threadLog"].label)
        }
        XCTAssertFalse(timestampLabels(in: app).firstMatch.exists)
        XCTAssertFalse(app.buttons["Cancel reply"].exists, "a left drag must not start a reply")
        rows[rows.count - 1].press(forDuration: 0.6)
        let timestamp = app.staticTexts["message.sent-time"]
        XCTAssertTrue(timestamp.waitForExistence(timeout: 5))
        XCTAssertTrue(timestamp.label.hasPrefix("Sent "))
        XCTAssertGreaterThan(timestamp.label.count, 12, "the menu must show a date and time")
        app.buttons["Close"].tap()
        XCTAssertTrue(timestamp.waitForNonExistence(timeout: 5))
    }

    private func timestampLabels(in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "room.timestamp."))
    }

    private func revealEnd(of message: XCUIElement, in app: XCUIApplication, thread: XCUIElement, field: XCUIElement) {
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        let top = max(thread.frame.minY, app.navigationBars.firstMatch.frame.maxY)
        for _ in 0..<8 {
            if message.frame.maxY >= top + 80 && message.frame.maxY <= field.frame.minY - 12 { break }
            if message.frame.maxY < top + 80 {
                thread.swipeDown(velocity: .slow)
            } else {
                thread.swipeUp(velocity: .slow)
            }
        }
        let log = app.descendants(matching: .any)["debug.threadLog"].label
        XCTAssertTrue(message.isHittable)
        XCTAssertGreaterThan(message.frame.height, 1_000)
        XCTAssertGreaterThanOrEqual(message.frame.maxY, top + 80, log)
        XCTAssertLessThanOrEqual(message.frame.maxY, field.frame.minY - 12, "\(message.frame) \(log)")
    }

    /// The crop is read from the window, the navigation bar and the composer alone. A blank
    /// conversation has no message row to take its bounds from, and that is exactly the
    /// state whose picture and recognized words must still be reported.
    private func verifyRenderedText(
        _ expected: String, in app: XCUIApplication, field: XCUIElement, named name: String
    ) throws {
        let screenshot = keepScreenshot(app, named: name)
        var report = "Expected fixture text: \(expected)\n"
        let image = try XCTUnwrap(screenshot.image.cgImage)
        let appFrame = app.frame
        let top = app.navigationBars.firstMatch.frame.maxY
        let bottom = field.frame.minY - 12
        XCTAssertGreaterThan(bottom, top, "the unobscured thread must have room for messages")
        let viewport = CGRect(x: appFrame.minX, y: top, width: appFrame.width, height: bottom - top)
            .intersection(appFrame)
        let scaleX = CGFloat(image.width) / appFrame.width
        let scaleY = CGFloat(image.height) / appFrame.height
        let crop = CGRect(
            x: (viewport.minX - appFrame.minX) * scaleX, y: (viewport.minY - appFrame.minY) * scaleY,
            width: viewport.width * scaleX, height: viewport.height * scaleY
        ).integral
        report += "Viewport in screen points: \(viewport)\nCrop in pixels: \(crop)\n"
        let cropped = try XCTUnwrap(image.cropping(to: crop))
        let croppedAttachment = XCTAttachment(image: UIImage(cgImage: cropped))
        croppedAttachment.name = name + "-thread-crop"
        croppedAttachment.lifetime = .keepAlways
        add(croppedAttachment)

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: cropped, options: [:]).perform([request])
        let observations = request.results ?? []
        report += "Recognized observations: \(observations.count)\n"
        var lines: [String] = []
        for observation in observations {
            let candidate = try XCTUnwrap(observation.topCandidates(1).first)
            report += "\(observation.boundingBox) confidence=\(candidate.confidence): \(candidate.string)\n"
            lines.append(candidate.string)
        }
        let observationAttachment = XCTAttachment(string: report)
        observationAttachment.name = name + "-ocr"
        observationAttachment.lifetime = .keepAlways
        add(observationAttachment)
        let rendered = lines.joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        XCTAssertTrue(rendered.contains(expected),
                      "\(name): the newest fixture text must be rendered above the composer and below navigation. "
                          + app.descendants(matching: .any)["debug.threadLog"].label)
    }

    @discardableResult
    private func keepScreenshot(_ app: XCUIApplication, named name: String) -> XCUIScreenshot {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return screenshot
    }
}

