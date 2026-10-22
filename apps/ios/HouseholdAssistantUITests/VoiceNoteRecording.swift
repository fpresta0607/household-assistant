// The composer's voice note gestures as a finger makes them, for the UI tests that send one
// (ChatSpeedTests, NewRowsLandInPlaceTests).

import XCTest

@MainActor
enum VoiceNoteRecording {
    /// Holds the microphone and slides up past the lock, as a finger would (MotionDemoTests).
    static func recordAndLock(with microphone: XCUIElement) {
        let start = microphone.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.8, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -160)))
    }

    /// Answers iOS's microphone question, when it is on screen.
    static func allowMicrophone() {
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 2) {
            allow.tap()
        }
    }

    /// Records a note and locks it, answering the microphone question the first time, and
    /// hands back the Send button. Skips the test when this simulator cannot record.
    static func lockedNote(in app: XCUIApplication) throws -> XCUIElement {
        let microphone = app.buttons["composer.microphone"]
        XCTAssertTrue(microphone.waitForExistence(timeout: 10), "the composer's microphone is missing")
        let send = app.buttons["Send voice note"]
        recordAndLock(with: microphone)
        if !send.waitForExistence(timeout: 3) {
            // The first touch asked iOS for the microphone instead of recording.
            allowMicrophone()
            recordAndLock(with: microphone)
        }
        try XCTSkipUnless(send.waitForExistence(timeout: 3), "no voice note could be recorded on this simulator")
        return send
    }
}
