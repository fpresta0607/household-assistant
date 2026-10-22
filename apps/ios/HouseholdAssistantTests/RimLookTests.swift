#if canImport(UIKit)
import SwiftUI
import XCTest
@testable import HouseholdAssistant

@MainActor
final class RimLookTests: XCTestCase {
    func testOriginalDefaultRimsAreUnchanged() {
        let look = RimLook()
        assertColors(look.bubble(isDark: true).colors, Palette.rimGold)
        assertColors(look.glass(isDark: true).colors, Palette.rimGold)
        assertColors(look.glass(isDark: false).colors, Palette.sheenColors)
        assertColors(look.bubble(isDark: false).colors, Palette.rimColors(rainbow: 0.75))
        XCTAssertEqual(look.glass(isDark: true).opacity, 0.7)
        XCTAssertEqual(look.glass(isDark: false).opacity, 0.75)
    }

    func testEverySeasonHasTheSameRimOnBubblesAndControls() throws {
        for theme in AppTheme.allCases where theme != .default {
            for dark in [false, true] {
                let expected = try XCTUnwrap(theme.colors(isDark: dark)).rim.map { Color(themeRGB: $0) }
                let look = RimLook(theme: theme)
                assertColors(look.bubble(isDark: dark).colors, expected)
                assertColors(look.glass(isDark: dark).colors, expected)
                XCTAssertEqual(look.glass(isDark: dark).opacity, 1)
            }
        }
    }

    func testChangingEitherPresetInvalidatesCachedRowLook() {
        XCTAssertNotEqual(RimLook(), RimLook(theme: .spring))
        XCTAssertNotEqual(RimLook(), RimLook(theme: .christmas))
        XCTAssertEqual(RimLook(theme: .winter), RimLook(theme: .winter))
    }

    private func assertColors(_ actual: [Color], _ expected: [Color]) {
        XCTAssertEqual(actual.count, expected.count)
        let environment = EnvironmentValues()
        for (actual, expected) in zip(actual, expected) {
            let a = actual.resolve(in: environment)
            let b = expected.resolve(in: environment)
            XCTAssertEqual(a.red, b.red, accuracy: 0.01)
            XCTAssertEqual(a.green, b.green, accuracy: 0.01)
            XCTAssertEqual(a.blue, b.blue, accuracy: 0.01)
        }
    }
}
#endif
