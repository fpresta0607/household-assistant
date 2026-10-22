#if canImport(UIKit)
import SwiftUI
import XCTest
@testable import HouseholdAssistant

@MainActor
final class AppearanceSettingsTests: XCTestCase {
    private var suiteName = ""
    private var defaults = UserDefaults.standard

    override func setUp() async throws {
        suiteName = "appearance-tests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        ThemeSelection.shared.theme = .default
    }

    func testNewPhoneKeepsBothOriginalDefaultsAndFollowsIPhone() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.appearance, .automatic)
        XCTAssertNil(settings.appearance.colorScheme)
        XCTAssertEqual(settings.theme, .default)
        XCTAssertNil(ThemeSelection.shared.palette(for: .light))
        XCTAssertNil(ThemeSelection.shared.palette(for: .dark))
    }

    func testUpgradeRemovesCustomOverridesWithoutChangingOtherPreferences() {
        defaults.set(true, forKey: "appearance-custom")
        defaults.set(Data("arbitrary custom colors".utf8), forKey: "appearance-materials")
        defaults.set("rose", forKey: "accent")
        defaults.set("dark", forKey: "appearance")
        defaults.set(true, forKey: "bold-text")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.appearance, .dark)
        XCTAssertTrue(settings.isTextBold)
        XCTAssertEqual(settings.theme, .default)
        for key in ["appearance-custom", "appearance-materials", "accent"] {
            XCTAssertNil(defaults.object(forKey: key))
        }
    }

    func testOneThemePersistsAcrossEveryAppearanceAndRelaunch() {
        let settings = AppSettings(defaults: defaults)
        for theme in AppTheme.allCases {
            settings.theme = theme
            for appearance in AppearanceChoice.allCases {
                settings.appearance = appearance
                let relaunched = AppSettings(defaults: defaults)
                XCTAssertEqual(relaunched.theme, theme)
                XCTAssertEqual(relaunched.appearance, appearance)
                XCTAssertEqual(ThemeSelection.shared.palette(for: .light), theme.colors(isDark: false))
                XCTAssertEqual(ThemeSelection.shared.palette(for: .dark), theme.colors(isDark: true))
            }
        }
    }

    func testLegacyNightThemeMigratesOnceAndDefaultRemainsDefault() {
        defaults.set("dark", forKey: "appearance")
        defaults.set("springBloom", forKey: "theme-light")
        defaults.set("winterNight", forKey: "theme-dark")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.theme, .winter)
        XCTAssertNil(defaults.object(forKey: "theme-light"))
        XCTAssertNil(defaults.object(forKey: "theme-dark"))
        settings.theme = .default
        XCTAssertEqual(AppSettings(defaults: defaults).theme, .default)
    }

    func testDynamicPaletteUsesBothVariantsAndRestoresDefaults() {
        let settings = AppSettings(defaults: defaults)
        let originalLight = resolved(Palette.text, dark: false)
        let originalDark = resolved(Palette.text, dark: true)
        for theme in AppTheme.allCases where theme != .default {
            settings.theme = theme
            for dark in [false, true] {
                assertColor(Palette.text, equals: theme.colors(isDark: dark)!.text, dark: dark)
                assertColor(Palette.highlight, equals: theme.colors(isDark: dark)!.accent, dark: dark)
            }
        }
        settings.revertAppearance()
        XCTAssertEqual(resolved(Palette.text, dark: false), originalLight)
        XCTAssertEqual(resolved(Palette.text, dark: true), originalDark)
    }

    private func resolved(_ color: Color, dark: Bool) -> UIColor {
        UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
    }

    private func assertColor(_ actual: Color, equals rgb: UInt32, dark: Bool) {
        XCTAssertEqual(resolved(actual, dark: dark), resolved(Color(themeRGB: rgb), dark: dark))
    }

}
#endif
