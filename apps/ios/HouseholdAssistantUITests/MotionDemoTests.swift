// The motion film: one fixed walk, about twenty seconds, through the moments the app
// animates, in the demo household. Pearl's Mac preview records the simulator while this
// runs (decision 1006924), so its name, its steps and its pauses stay the same from run to
// run.
//
// The app opens in the demo's motion scene (DemoGateway), which waits for Corey's thread
// to open and then has Corey answer with a card and a picture. In order: Chats makes its
// entrance, Corey's thread slides in, his answer rises in with a glimmer on
// its rim, its card, the chip saying what it changed and then a picture come into focus,
// the picture zooms into the viewer and back into its place, and the composer's glass
// flows into the bar a voice note records in, and back.
//
// A simulator that has never been allowed the microphone asks once, and the film then
// shows iOS's question. Granting it before the run keeps every take alike. One with no
// microphone at all shows the composer's notice instead of a note, and the film still ends.

import XCTest

// On the main actor, where XCUIApplication and every query live.
@MainActor
final class MotionDemoTests: XCTestCase {
    nonisolated override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testMotionDemo() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-StewardDemo", "YES", "-StewardMotionDemo", "YES"]
        app.launch()

        // The entrance: the page settles, the pins rise one after another, the bar arrives.
        let corey = app.buttons["pin.direct"]
        XCTAssertTrue(corey.waitForExistence(timeout: 30), "Corey's pin never showed")
        hold(1.5)

        // Corey's thread zooms out of his face, and his answer arrives: it rises with a
        // glimmer along its rim, then its card and a picture come into focus. The picture
        // is the thread's only one, and Chats' "Photo from Rosa" is behind it.
        corey.tap()
        let picture = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ AND NOT (label CONTAINS %@)", "Photo", "from"))
            .firstMatch
        XCTAssertTrue(picture.waitForExistence(timeout: 20), "Corey's picture never arrived")
        hold(2)

        // The picture zooms into the viewer, and back into its place in the thread.
        picture.tap()
        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), "the viewer never opened")
        hold(2)
        close.tap()
        hold(1.5)

        // The composer's glass flows into the bar a voice note records in, locked so it
        // stays, and back once the note is thrown away.
        let microphone = app.buttons["composer.microphone"]
        XCTAssertTrue(microphone.waitForExistence(timeout: 5), "the composer's microphone is missing")
        recordAndLock(with: microphone)
        let delete = app.buttons["Delete voice note"]
        if !delete.waitForExistence(timeout: 2) {
            // The first touch asked iOS for the microphone instead of recording.
            allowMicrophone()
            recordAndLock(with: microphone)
        }
        if delete.waitForExistence(timeout: 3) {
            hold(2)
            delete.tap()
        }
        hold(1.5)
    }

    /// Holds the microphone and slides up past the lock, as a finger would.
    private func recordAndLock(with microphone: XCUIElement) {
        let start = microphone.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.8, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -160)))
    }

    /// Answers iOS's microphone question, when it is on screen.
    private func allowMicrophone() {
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 2) {
            allow.tap()
            hold(0.5)
        }
    }

    /// Lets what is on screen play out for the film, the same length every run.
    private func hold(_ seconds: TimeInterval) {
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "the film holds")], timeout: seconds)
    }
}
