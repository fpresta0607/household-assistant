// How long Steward AI takes from a tap on its icon until it answers a touch, with the
// welcome playing over Chats and without it (CFO notes section 21e). The welcome draws in a
// window of its own while Chats is drawn and the app reconnects underneath, so it must not
// make the app any slower to be ready. Five launches each.

import XCTest

// On the main actor, where XCUIApplication and every query live.
@MainActor
final class LaunchSpeedTests: XCTestCase {
    func testLaunchingWithoutTheWelcomeIsTimed() {
        measureLaunch(isWelcomeShown: false)
    }

    func testLaunchingWithTheWelcomeIsTimed() {
        measureLaunch(isWelcomeShown: true)
    }

    private func measureLaunch(isWelcomeShown: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["-StewardDemo", "YES", "-StewardWelcome", isWelcomeShown ? "YES" : "NO"]
        let options = XCTMeasureOptions()
        options.iterationCount = 5

        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: options) {
            app.launch()
        }
        app.terminate()
    }
}
