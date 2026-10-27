// The composer as a finger uses it, the same on every phone (CFO notes for
// ha-gia-appearance, sections 1 and 2): the plus opens the apps drawer in each
// conversation and its tiles answer, and a voice note goes the way Telegram's and
// Messages' go. Hold and let go sends it, hold and slide up locks it until the send
// arrow sends it, a tap records hands-free the same way (the microphone never dictates,
// notes section 4), and hold and slide left throws it away. The recording shows the
// moment the finger lands, on its own frame, cold and warm (sections 6 and 8). And from the
// thread's header, Edit Color on the assistant's page picks the ring round its face
// (section 4), and on the Fam's page its color and appearance, each a line in the room
// (section 8). Corey's demo thread has no voice
// note of its own, so a note in it is the one the test sent. Every failure says what the
// thread and the composer logged last (ThreadLog), which names the layer that failed.

import SwiftUI
import UIKit
import XCTest

// On the main actor, where XCUIApplication and every query live.
@MainActor
final class ComposerGesturesTests: XCTestCase {
    nonisolated override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testPastedScreenshotAppearsInTheTrayAndCanBeSent() throws {
        let thread = openThread("pin.direct")
        let field = thread.app.textViews["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Read this chart")
        UIPasteboard.general.image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }
        field.press(forDuration: 0.8)
        let paste = thread.app.menuItems["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        paste.tap()
        let photo = thread.app.buttons["Take out Photo"]
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        XCTAssertEqual(field.value as? String, "Read this chart")
        let attachment = XCTAttachment(screenshot: thread.app.screenshot())
        attachment.name = "pasted-screenshot-in-composer"
        attachment.lifetime = .keepAlways
        add(attachment)
        thread.app.buttons["Send"].tap()
        XCTAssertTrue(photo.waitForNonExistence(timeout: 5))
        field.tap()
        field.typeText("Next message")
        XCTAssertEqual(field.value as? String, "Next message")
    }

    func testSendingClearsTheFieldAndKeepsTheNextDraft() throws {
        for pin in ["pin.direct", "pin.family"] {
            for keepKeyboard in [true, false] {
                let thread = openThread(pin)
                let field = thread.app.textViews["composer.field"]
                XCTAssertTrue(field.waitForExistence(timeout: 10))
                field.tap()
                field.typeText("Hello from the composer\nA second line to clear when sent")
                XCTAssertTrue(thread.app.keyboards.firstMatch.waitForExistence(timeout: 5))
                if !keepKeyboard {
                    thread.app.collectionViews["room.thread"].swipeDown(velocity: .slow)
                    XCTAssertTrue(thread.app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
                }
                thread.app.buttons["Send"].tap()
                let cleared = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "value == %@ OR value == %@", "", "Message"), object: field)
                XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: 5), .completed)
                XCTAssertTrue(thread.app.descendants(matching: .any)["composer.microphone"].waitForExistence(timeout: 2))
                XCTAssertEqual(thread.app.keyboards.firstMatch.exists, keepKeyboard)
                let attachment = XCTAttachment(screenshot: thread.app.screenshot())
                attachment.name = "sent-reset-\(pin)-keyboard-\(keepKeyboard)"
                attachment.lifetime = .keepAlways
                add(attachment)
                field.tap()
                field.typeText("My next draft")
                XCTAssertEqual(field.value as? String, "My next draft")
                thread.app.terminate()
            }
        }
    }

    func testThePlusOpensTheAppsAndTheirTilesAnswerInEachConversation() throws {
        for pin in ["pin.direct", "pin.family"] {
            // Arrange
            let thread = openThread(pin)
            let plus = thread.app.buttons["composer.plus"]
            XCTAssertTrue(plus.waitForExistence(timeout: 10), "\(pin): the composer's plus is missing")

            // Act
            plus.tap()

            // Assert
            for tile in ["Photos", "Camera", "Files", "Contact", "Location", "Link"] {
                let pressable = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "exists == true AND isHittable == true"),
                    object: thread.app.buttons[tile]
                )
                XCTAssertEqual(XCTWaiter.wait(for: [pressable], timeout: 5), .completed, "\(pin): \(tile) cannot be pressed. \(thread.log)")
            }
            thread.app.buttons["Link"].tap()
            let alert = thread.app.alerts["Add a link"]
            XCTAssertTrue(alert.waitForExistence(timeout: 5), "\(pin): the Link tile did nothing. \(thread.log)")
            alert.buttons["Cancel"].tap()
            thread.app.terminate()
        }
    }

    func testHoldingTheMicrophoneAndLettingGoSendsTheNote() throws {
        // Arrange
        let thread = openThread("pin.direct")
        let microphone = try readyMicrophone(in: thread)

        // Act
        microphone.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 2.5)

        // Assert
        XCTAssertTrue(thread.sentNote.waitForExistence(timeout: 10), "letting go did not send the note. \(thread.log)")
        XCTAssertFalse(thread.app.buttons["Send voice note"].exists, "letting go left the note waiting. \(thread.log)")
        XCTAssertTrue(microphone.waitForExistence(timeout: 5), "the microphone never came back. \(thread.log)")
    }

    func testTappingTheMicrophoneRecordsHandsFreeAndNeverDictates() throws {
        // Arrange
        let thread = openThread("pin.direct")
        let microphone = try readyMicrophone(in: thread)

        // Act
        microphone.tap()

        // Assert
        let send = thread.app.buttons["Send voice note"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "a tap did not record hands-free. \(thread.log)")
        XCTAssertTrue(thread.app.buttons["Delete voice note"].exists, "the hands-free note has no bin. \(thread.log)")
        XCTAssertFalse(thread.sentNote.exists, "a tap sent the note before the arrow. \(thread.log)")
        send.tap()
        XCTAssertTrue(thread.sentNote.waitForExistence(timeout: 10), "the arrow did not send the note. \(thread.log)")
    }

    /// From the finger landing to the recording on screen, and to the microphone's input
    /// started behind it, which the touch used to wait for before anything showed (notes
    /// section 6). The app times both itself (ChatTiming); the measure keeps them in the run's
    /// metrics, and the bound is many frames wide so only a touch waiting on the sound fails.
    /// The first recording after the app opens, the cold press, and five more, the warm
    /// ones: each shows and settles, nothing still easing in, on the touch's own frame
    /// (notes section 8). The microphone's input starts right behind it.
    func testTheRecordingShowsAtOnceAndIsTimed() throws {
        // Arrange
        let thread = openThread("pin.direct")
        let microphone = try readyMicrophone(in: thread)
        let cold = (
            shown: Self.firstMilliseconds(after: "voice note shown in ", in: thread.log),
            settled: Self.firstMilliseconds(after: "voice note settled in ", in: thread.log)
        )
        let start = microphone.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        let metrics = ["voice note shown", "voice note settled", "voice note capture"].map {
            XCTOSSignpostMetric(subsystem: "com.siqstack.stewardai", category: "chat", name: $0)
        }
        var shown: [Int] = []
        var settled: [Int] = []

        // Act
        measure(metrics: metrics, options: options) {
            start.press(forDuration: 0.8, thenDragTo: start.withOffset(CGVector(dx: -180, dy: 0)))
            XCTAssertTrue(microphone.waitForExistence(timeout: 5), "the microphone never came back. \(thread.log)")
            if let milliseconds = Self.lastMilliseconds(after: "voice note shown in ", in: thread.log) {
                shown.append(milliseconds)
            }
            if let milliseconds = Self.lastMilliseconds(after: "voice note settled in ", in: thread.log) {
                settled.append(milliseconds)
            }
        }

        // Assert
        // What the recording took to settle before, eased in on the composer's press spring.
        let before = Spring(response: 0.25, dampingRatio: 0.7).settlingDuration
        print("voice note timing: cold shown \(cold.shown ?? -1) ms, settled \(cold.settled ?? -1) ms; warm shown \(shown) ms, settled \(settled) ms; the press spring alone settled in \(Int(before * 1000)) ms")
        XCTAssertLessThan(cold.shown ?? .max, 100, "the first recording showed \(cold.shown ?? -1) ms after the touch. \(thread.log)")
        XCTAssertFalse(shown.isEmpty, "the recording never said when it showed. \(thread.log)")
        XCTAssertLessThan(shown.max() ?? .max, 100, "the recording showed \(shown) ms after the touch. \(thread.log)")
        XCTAssertFalse(settled.isEmpty, "the recording never said when it settled. \(thread.log)")
        XCTAssertLessThan(settled.max() ?? .max, 100, "the recording settled \(settled) ms after the touch. \(thread.log)")
    }

    func testHoldingAndSlidingUpLocksTheNoteUntilTheArrowSendsIt() throws {
        // Arrange
        let thread = openThread("pin.direct")
        let microphone = try readyMicrophone(in: thread)

        // Act
        VoiceNoteRecording.recordAndLock(with: microphone)
        let send = thread.app.buttons["Send voice note"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "sliding up did not lock the note. \(thread.log)")
        XCTAssertFalse(thread.sentNote.exists, "the locked note went before the arrow. \(thread.log)")
        send.tap()

        // Assert
        XCTAssertTrue(thread.sentNote.waitForExistence(timeout: 10), "the arrow did not send the note. \(thread.log)")
        XCTAssertTrue(microphone.waitForExistence(timeout: 5), "the microphone never came back. \(thread.log)")
    }

    func testHoldingAndSlidingLeftThrowsTheNoteAway() throws {
        // Arrange
        let thread = openThread("pin.direct")
        let microphone = try readyMicrophone(in: thread)
        let start = microphone.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))

        // Act
        start.press(forDuration: 0.8, thenDragTo: start.withOffset(CGVector(dx: -180, dy: 0)))

        // Assert
        XCTAssertTrue(microphone.waitForExistence(timeout: 5), "the microphone never came back. \(thread.log)")
        XCTAssertFalse(thread.app.buttons["Send voice note"].exists, "sliding left left the note waiting. \(thread.log)")
        XCTAssertFalse(thread.sentNote.waitForExistence(timeout: 3), "a note thrown away was sent. \(thread.log)")
    }

    /// Edit Color in the assistant's photo menu on its page picks the ring round its face,
    /// and the face then says it is in that ring (notes section 4).
    func testEditColorOnTheAssistantsPagePicksTheRingRoundItsFace() throws {
        // Arrange
        let thread = openThread("pin.direct")
        let header = thread.app.buttons["room.header"]
        XCTAssertTrue(header.waitForExistence(timeout: 10), "the thread has no header to open Corey's page")
        header.tap()
        let face = thread.app.descendants(matching: .any)["contact.face"]
        XCTAssertTrue(face.waitForExistence(timeout: 10), "Corey's page has no face to change")

        // Act
        face.tap()
        let editColor = thread.app.buttons["Edit Color"]
        XCTAssertTrue(editColor.waitForExistence(timeout: 5), "the photo menu has no Edit Color")
        editColor.tap()
        let rose = thread.app.buttons["Rose"]
        XCTAssertTrue(rose.waitForExistence(timeout: 5), "Edit Color opened no ring colours")
        rose.tap()
        thread.app.buttons["Done"].tap()

        // Assert
        let picked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Rose ring"), object: face)
        XCTAssertEqual(XCTWaiter.wait(for: [picked], timeout: 5), .completed, "the face's ring did not change: \(face.value ?? "none")")
    }

    /// The Fam's color and appearance, edited on its page, are the room's: its face wears
    /// the color, and the room shows a line with its time for each change (notes section 8).
    func testTheFamsColorAndAppearanceAreEditedOnItsPageAndLinedInTheRoom() throws {
        // Arrange
        let thread = openThread("pin.family")
        let header = thread.app.buttons["room.header"]
        XCTAssertTrue(header.waitForExistence(timeout: 10), "the Fam has no header to open its page")
        header.tap()
        let face = thread.app.descendants(matching: .any)["family.face"]
        XCTAssertTrue(face.waitForExistence(timeout: 10), "the Fam's page has no face to change")

        // Act
        face.tap()
        let editColor = thread.app.buttons["Edit Color"]
        XCTAssertTrue(editColor.waitForExistence(timeout: 5), "the Fam's photo menu has no Edit Color")
        editColor.tap()
        let rose = thread.app.buttons["Rose"]
        XCTAssertTrue(rose.waitForExistence(timeout: 5), "Edit Color opened no colors for the Fam")
        rose.tap()
        thread.app.buttons["Done"].tap()
        let picked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Rose ring"), object: face)
        XCTAssertEqual(XCTWaiter.wait(for: [picked], timeout: 5), .completed, "the Fam's ring did not change: \(face.value ?? "none")")
        let custom = thread.app.buttons["Custom"]
        XCTAssertTrue(custom.waitForExistence(timeout: 5), "the Fam's page has no Custom appearance")
        custom.tap()
        let night = thread.app.buttons["Night"]
        XCTAssertTrue(night.waitForExistence(timeout: 5), "Custom offered no background for the Fam")
        night.tap()
        thread.app.buttons["Message"].tap()

        // Assert
        // Each line sits where its time puts it. The demo's messages read as set times of
        // day, some still to come, so before those times the lines sort above them, at the
        // room's oldest end, and are looked for there too.
        let list = thread.app.collectionViews["room.thread"]
        let lines = list.descendants(matching: .any).matching(identifier: "room.look-line")
        let three = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 3"), object: lines)
        _ = XCTWaiter.wait(for: [three], timeout: 10)
        var words = Set(lines.allElementsBoundByIndex.map(\.label))
        for _ in 0..<3 where words.count < 3 {
            list.swipeDown()
            words.formUnion(lines.allElementsBoundByIndex.map(\.label))
        }
        XCTAssertEqual(words.count, 3, "the room showed \(words.count) lines for three changes: \(words). \(thread.log)")
        for said in ["Leo changed the group color", "Leo set the group's appearance to Custom", "Leo changed the group's background to Night"] {
            XCTAssertTrue(words.contains { $0.hasPrefix(said) }, "no line says \"\(said)\": \(words)")
        }
    }

    /// The number in the newest log line that starts with `prefix` and ends in " ms".
    private static func lastMilliseconds(after prefix: String, in log: String) -> Int? {
        log.range(of: prefix, options: .backwards).flatMap { Int(log[$0.upperBound...].prefix { $0.isNumber }) }
    }

    /// The same in the oldest line the log still holds.
    private static func firstMilliseconds(after prefix: String, in log: String) -> Int? {
        log.range(of: prefix).flatMap { Int(log[$0.upperBound...].prefix { $0.isNumber }) }
    }

    // MARK: - The way there

    @MainActor
    private struct OpenThread {
        let app: XCUIApplication

        /// A voice note in the thread, which in Corey's demo thread is one the test sent.
        var sentNote: XCUIElement {
            app.collectionViews["room.thread"].descendants(matching: .any)
                .matching(identifier: "room.message")
                .matching(NSPredicate(format: "label CONTAINS[c] %@", "voice note"))
                .firstMatch
        }

        /// What the thread and the composer logged last.
        var log: String {
            let element = app.descendants(matching: .any)["debug.threadLog"]
            return element.exists ? element.label : "(no log)"
        }
    }

    /// The demo with its rows added only on a cue, which none of these gives, so its own
    /// scene, which opens The Fam by itself a moment after launch, never plays.
    private func openThread(_ pin: String) -> OpenThread {
        let app = XCUIApplication()
        let control = "steward-composer-" + UUID().uuidString
        app.launchArguments = ["-StewardDemo", "YES", "-StewardNewRowsControl", control, "-StewardThreadLog", "YES"]
        app.launch()
        let chat = app.buttons[pin]
        XCTAssertTrue(chat.waitForExistence(timeout: 30), "Chats never showed")
        chat.tap()
        XCTAssertTrue(app.collectionViews["room.thread"].waitForExistence(timeout: 10), "the thread never showed")
        return OpenThread(app: app)
    }

    /// The microphone, once a first note has recorded, locked and been thrown away, which
    /// also answers iOS's question about the microphone, so the gesture under test records
    /// from its first touch. Skips the test when this simulator cannot record, and fails it
    /// when a note started and never locked, which is the app's doing, not the simulator's.
    private func readyMicrophone(in thread: OpenThread) throws -> XCUIElement {
        let microphone = thread.app.buttons["composer.microphone"]
        XCTAssertTrue(microphone.waitForExistence(timeout: 10), "the composer's microphone is missing")
        let send = thread.app.buttons["Send voice note"]
        VoiceNoteRecording.recordAndLock(with: microphone)
        if !send.waitForExistence(timeout: 3) {
            // The first touch asked iOS for the microphone instead of recording.
            VoiceNoteRecording.allowMicrophone()
            VoiceNoteRecording.recordAndLock(with: microphone)
        }
        if !send.waitForExistence(timeout: 3) {
            let log = thread.log
            XCTAssertFalse(
                log.contains("voice note started") || log.contains("voice note finished"),
                "a note started but sliding up never locked it. \(log)"
            )
            throw XCTSkip("no voice note could be recorded on this simulator. \(log)")
        }
        let bin = thread.app.buttons["Delete voice note"]
        XCTAssertTrue(bin.waitForExistence(timeout: 3), "a locked note has no bin. \(thread.log)")
        bin.tap()
        XCTAssertTrue(microphone.waitForExistence(timeout: 5), "the microphone never came back after the first note. \(thread.log)")
        XCTAssertFalse(thread.sentNote.exists, "the note thrown away was sent. \(thread.log)")
        return microphone
    }
}

