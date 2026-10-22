import XCTest

@MainActor
final class AppearanceModesTests: XCTestCase {
    nonisolated override func setUpWithError() throws { continueAfterFailure = false }

    func testOneThemeWorksInLightDarkAndAuto() {
        let app = XCUIApplication()
        app.launchArguments = ["-StewardDemo", "YES", "-StewardNewRowsControl", "appearance-paired-" + UUID().uuidString]
        app.launch()
        openAppearance(app)
        XCTAssertFalse(app.buttons["appearance.theme.light"].exists)
        XCTAssertFalse(app.buttons["appearance.theme.dark"].exists)
        for theme in ["Aurora", "Ember", "Starlight", "Winter", "Spring", "Christmas", "Default"] {
            choose(theme, menu: "appearance.theme", app: app)
            for mode in ["Light", "Dark", "Auto"] {
                app.segmentedControls["appearance.mode"].buttons[mode].tap()
                capture(theme.lowercased() + "-" + mode.lowercased(), app)
                let selection = selected(app.buttons["appearance.theme"])
                XCTAssertTrue(selection.contains(theme), "Expected \(theme) in \(mode), got \(selection)")
                if mode != "Auto" {
                    let preview = app.descendants(matching: .any)
                        .matching(identifier: "appearance.preview." + mode.lowercased()).firstMatch
                    XCTAssertTrue(preview.waitForExistence(timeout: 5))
                    XCTAssertEqual(preview.label, "Sample chat in \(theme), \(mode)")
                }
            }
        }
        XCTAssertFalse(app.buttons["Custom"].exists)
    }

    private func openAppearance(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["pin.direct"].waitForExistence(timeout: 30))
        app.navigationBars.buttons["Settings"].tap()
        let appearance = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Appearance")).firstMatch
        show(appearance, app)
        appearance.tap()
        XCTAssertTrue(app.buttons["appearance.theme"].waitForExistence(timeout: 5))
    }

    private func choose(_ name: String, menu: String, app: XCUIApplication, towardTop: Bool = false) {
        let picker = app.buttons[menu]
        show(picker, app, towardTop: towardTop)
        picker.tap()
        let option = app.buttons.matching(identifier: name).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        option.tap()
    }

    private func show(_ element: XCUIElement, _ app: XCUIApplication, towardTop: Bool = false) {
        for _ in 0..<6 {
            if element.exists && element.isHittable { break }
            if towardTop { app.swipeDown() } else { app.swipeUp() }
        }
        XCTAssertTrue(element.exists && element.isHittable)
    }

    private func selected(_ picker: XCUIElement) -> String {
        picker.label + " " + (picker.value as? String ?? "")
    }

    private func capture(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
