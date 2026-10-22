// Placeholder UI test.
//
// It proves the app launches and stays in the foreground on the simulator,
// which is the cheapest thing that fails when signing, embedding the widget
// extension, or the Info.plist go wrong.

import XCTest

// On the main actor, where XCUIApplication and every query live.
@MainActor
final class LaunchUITests: XCTestCase {
    nonisolated override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAppLaunches() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
    }
}
