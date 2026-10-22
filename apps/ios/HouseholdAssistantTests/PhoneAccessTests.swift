// Where Contacts, adding to Photos, the camera and Face ID stand, in the app's words, and
// which of them only iOS can turn on, where Settings opens Steward AI's page in the
// iPhone's Settings instead of a switch.

import XCTest
@testable import HouseholdAssistant

final class PhoneAccessTests: XCTestCase {
    func testEachStateReadsInTheAppsWordsAndOnlyOffOrNotSetUpIsLeftToIOS() {
        // Arrange
        let expected: [(state: PhoneAccessState, label: String, isUpToIOS: Bool)] = [
            (.notAsked, "Not asked", false),
            (.allowed, "On", false),
            (.limited, "Limited", false),
            (.denied, "Off", true),
            (.unavailable, "Not set up", true),
        ]

        for (state, label, isUpToIOS) in expected {
            // Act, Assert
            XCTAssertEqual(state.label, label, "\(state)")
            XCTAssertEqual(state.isUpToIOS, isUpToIOS, "\(state)")
        }
    }
}
