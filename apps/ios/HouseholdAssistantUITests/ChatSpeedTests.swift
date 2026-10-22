// How long each thing the owner does in Corey's chat takes, on a thread shaped like his
// real one (DemoHeavyThread): opening it, online and offline, backing out, typing, sending
// a message, sending a voice note and scrolling, each timed three times by the clock and
// by the app's own CPU time. CFO notes section 21: build 14 was extremely slow at every
// one of them, so these are the numbers before and after the fix, taken the same way on
// the same thread. ThousandsChatSpeedTests takes them again on a thread of thousands.
//
// The clock here includes the test's own reading of the screen, which is slow on a long
// thread, so the waits the owner feels are also timed inside the app by its signposts
// (ChatTiming): tap to the newest row on screen, and Send to the sent row on screen. The
// system's own signposts time each push and pop and the scroll, with their hitches.

import XCTest

// On the main actor, where XCUIApplication and every query live.
@MainActor
class ChatSpeedTests: XCTestCase {
    private static let newest = "Heavy thread newest message."
    private static let subsystem = "com.siqstack.stewardai"

    /// How many times over Corey's four days the thread holds.
    class var repeats: Int {
        1
    }

    nonisolated override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testOpeningTheHeavyThreadIsTimed() throws {
        let app = launchHeavyThread()
        let pin = app.buttons["pin.direct"]
        let newest = newestMessage(in: app)

        measure(metrics: metrics(app, timing: "open") + [XCTOSSignpostMetric.navigationTransitionMetric], options: Self.threeTimesByHand()) {
            startMeasuring()
            pin.tap()
            XCTAssertTrue(newest.waitForExistence(timeout: 20), "the thread never showed its newest message")
            stopMeasuring()
            backToChats(in: app)
        }
    }

    /// Offline, the thread opens from what the phone kept the last time it was online.
    func testOpeningTheHeavyThreadOfflineIsTimed() throws {
        let online = launchHeavyThread(also: ["-StewardKeepThreads", "YES"])
        // The phone writes what it keeps a moment after the pages settle.
        Thread.sleep(forTimeInterval: 3)
        online.terminate()
        let app = launchHeavyThread(also: ["-StewardKeepThreads", "YES", "-StewardOffline", "YES"])
        let pin = app.buttons["pin.direct"]
        let newest = newestMessage(in: app)

        measure(metrics: metrics(app, timing: "open"), options: Self.threeTimesByHand()) {
            startMeasuring()
            pin.tap()
            XCTAssertTrue(newest.waitForExistence(timeout: 20), "offline, the thread never showed its newest message")
            stopMeasuring()
            backToChats(in: app)
        }
    }

    func testBackingOutOfTheHeavyThreadIsTimed() throws {
        let app = launchHeavyThread()
        let pin = app.buttons["pin.direct"]
        let newest = newestMessage(in: app)

        measure(metrics: metrics(app) + [XCTOSSignpostMetric.navigationTransitionMetric], options: Self.threeTimesByHand()) {
            pin.tap()
            XCTAssertTrue(newest.waitForExistence(timeout: 20), "the thread never showed its newest message")
            startMeasuring()
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(pin.waitForExistence(timeout: 20) && pin.isHittable, "Chats never came back")
            stopMeasuring()
        }
    }

    func testTypingInTheHeavyThreadIsTimed() throws {
        let app = launchHeavyThread()
        let field = openThread(in: app)
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "the keyboard never rose")
        let words = "Leaving now, see you at six"

        measure(metrics: metrics(app), options: Self.threeTimesByHand()) {
            startMeasuring()
            field.typeText(words)
            stopMeasuring()
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: words.count))
        }
    }

    func testSendingInTheHeavyThreadIsTimed() throws {
        let app = launchHeavyThread()
        let field = openThread(in: app)
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "the keyboard never rose")
        var sent = 0

        measure(metrics: metrics(app, timing: "send"), options: Self.threeTimesByHand()) {
            sent += 1
            let words = "Sent message \(sent)"
            field.typeText(words)
            startMeasuring()
            app.buttons["Send"].tap()
            let bubble = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "room.message", words))
                .firstMatch
            XCTAssertTrue(bubble.waitForExistence(timeout: 20), "the sent message never showed")
            stopMeasuring()
        }
    }

    /// From the tap on Send to the composer's microphone back, which needs the thread to
    /// have taken the note: counting voice notes would depend on which rows are drawn.
    func testSendingAVoiceNoteInTheHeavyThreadIsTimed() throws {
        let app = launchHeavyThread()
        _ = openThread(in: app)
        let microphone = app.buttons["composer.microphone"]
        let send = try VoiceNoteRecording.lockedNote(in: app)
        send.tap()
        XCTAssertTrue(microphone.waitForExistence(timeout: 20), "the composer never came back after the first note")

        measure(metrics: metrics(app, timing: "voice note"), options: Self.threeTimesByHand()) {
            VoiceNoteRecording.recordAndLock(with: microphone)
            XCTAssertTrue(send.waitForExistence(timeout: 5), "the note did not lock")
            startMeasuring()
            send.tap()
            XCTAssertTrue(microphone.waitForExistence(timeout: 20), "the composer never came back")
            stopMeasuring()
        }
    }

    func testScrollingTheHeavyThreadIsTimed() throws {
        let app = launchHeavyThread()
        _ = openThread(in: app)
        let thread = app.collectionViews["room.thread"]
        XCTAssertTrue(thread.waitForExistence(timeout: 10))
        let options = XCTMeasureOptions()
        options.iterationCount = 3

        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric] + metrics(app), options: options) {
            thread.swipeDown(velocity: .fast)
            thread.swipeUp(velocity: .fast)
        }
    }

    // MARK: - The way there

    private func launchHeavyThread(also arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-StewardDemo", "YES", "-StewardHeavyThread", "YES", "-StewardHeavyThreadRepeats", "\(Self.repeats)"]
            + arguments
        app.launch()
        XCTAssertTrue(app.buttons["pin.direct"].waitForExistence(timeout: 30), "Chats never showed")
        return app
    }

    private func newestMessage(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "room.message", Self.newest))
            .firstMatch
    }

    /// Opens Corey's thread and hands back its message field.
    private func openThread(in app: XCUIApplication) -> XCUIElement {
        app.buttons["pin.direct"].tap()
        XCTAssertTrue(newestMessage(in: app).waitForExistence(timeout: 20), "the thread never showed its newest message")
        let field = app.descendants(matching: .any).matching(identifier: "composer.field").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the message field is missing")
        return field
    }

    private func backToChats(in app: XCUIApplication) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["pin.direct"].waitForExistence(timeout: 20), "Chats never came back")
    }

    /// The clock and the app's CPU time, and with `timing` the app's own signposted wait.
    private func metrics(_ app: XCUIApplication, timing: String? = nil) -> [XCTMetric] {
        let measured: [XCTMetric] = [XCTClockMetric(), XCTCPUMetric(application: app)]
        guard let timing else {
            return measured
        }
        return measured + [XCTOSSignpostMetric(subsystem: Self.subsystem, category: "chat", name: timing)]
    }

    private static func threeTimesByHand() -> XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        return options
    }
}
