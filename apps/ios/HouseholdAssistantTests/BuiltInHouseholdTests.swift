// A build is the first household's only when its xcconfig names that household's box. A
// build for every household keeps the checked-in placeholder, and its onboarding then
// names nobody and pairs only with a setup link.

import XCTest
@testable import HouseholdAssistant

final class BuiltInHouseholdTests: XCTestCase {
    func testABoxsTailnetNameMakesTheBuildThatHouseholds() {
        XCTAssertTrue(HouseholdMember.namesABox("box.tail1234.ts.net"))
    }

    func testThePlaceholdersNameNoBox() {
        XCTAssertFalse(HouseholdMember.namesABox(HouseholdMember.placeholderHost))
        XCTAssertFalse(HouseholdMember.namesABox("household.example.ts.net"))
        XCTAssertFalse(HouseholdMember.namesABox("<machine>.<tailnet>.ts.net"))
        XCTAssertFalse(HouseholdMember.namesABox(""))
        XCTAssertFalse(HouseholdMember.namesABox("  "))
    }

    func testOutsideAnAppBundleTheBuildIsForEveryHousehold() {
        // Under `swift test` there is no Info.plist, so the placeholder stands.
        if Bundle.main.object(forInfoDictionaryKey: "HouseholdGatewayHost") == nil {
            XCTAssertFalse(HouseholdMember.isBuiltIn)
        }
    }
}
