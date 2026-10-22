#if canImport(UIKit)
// The choices this phone keeps for itself: App Lock off and asking again immediately on a
// new phone, the Contacts connector off until its person turns it on, and each of them kept
// for the next time the app opens.

import XCTest
@testable import HouseholdAssistant

@MainActor
final class PrivacySettingsTests: XCTestCase {
    private var suiteName = ""
    private var defaults = UserDefaults.standard

    override func setUp() async throws {
        suiteName = "privacy-tests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testANewPhoneHasNoLockAndContactsOff() {
        // Act
        let settings = AppSettings(defaults: defaults)

        // Assert
        XCTAssertFalse(settings.isAppLockOn)
        XCTAssertEqual(settings.appLockTiming, .immediately)
        XCTAssertFalse(settings.shouldLookInContacts)
    }

    func testTheOlderPrivacySwitchLeavesTheConnectorOff() {
        // Arrange: Privacy's Contacts switch, on, as a build before the connector kept it.
        defaults.set(true, forKey: "contacts-lookup")

        // Act
        let settings = AppSettings(defaults: defaults)

        // Assert
        XCTAssertFalse(settings.shouldLookInContacts, "the connector is off until its person turns it on")
    }

    func testEachChoiceIsKeptForTheNextOpen() {
        // Arrange
        let settings = AppSettings(defaults: defaults)

        // Act
        settings.isAppLockOn = true
        settings.appLockTiming = .afterFifteenMinutes
        settings.shouldLookInContacts = true
        let reopened = AppSettings(defaults: defaults)

        // Assert
        XCTAssertTrue(reopened.isAppLockOn)
        XCTAssertEqual(reopened.appLockTiming, .afterFifteenMinutes)
        XCTAssertTrue(reopened.shouldLookInContacts)
    }
}
#endif
