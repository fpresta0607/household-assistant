// The rim each scheme draws: the rainbow sheen in the light and gold glass in the dark as
// the app ships.

import XCTest
@testable import HouseholdAssistant

final class RimStyleTests: XCTestCase {
    func testTheStandardRimIsTheRainbowInTheLightAndGoldGlassInTheDark() {
        // Arrange
        let rim = RimStyle.standard

        // Act and Assert
        XCTAssertEqual(rim.rainbow(isDark: false), 0.75, "the light keeps the look it first shipped with")
        XCTAssertEqual(rim.rainbow(isDark: true), 0, "the dark has no rainbow in it")
    }

}
