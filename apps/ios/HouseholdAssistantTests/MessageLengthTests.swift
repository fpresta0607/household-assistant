// The composer holds back a message the gateway would refuse, at the gateway's own count:
// UTF-16 units of the trimmed words, 64,000 at most (room.js MAX_PERSON_MESSAGE_UNITS).

import XCTest
@testable import HouseholdAssistant

final class MessageLengthTests: XCTestCase {
    func testTheLimitCountsUTF16UnitsOfTheTrimmedWords() {
        let cases: [(String, String, Bool)] = [
            ("exactly the limit", String(repeating: "a", count: 64_000), false),
            ("one unit over", String(repeating: "a", count: 64_001), true),
            ("spaces around do not count", "  " + String(repeating: "a", count: 64_000) + "\n\n", false),
            ("an emoji is two units", String(repeating: "a", count: 63_998) + "🏡", false),
            ("an emoji past the limit", String(repeating: "a", count: 63_999) + "🏡", true),
            ("empty", "", false),
        ]
        for (name, text, isTooLong) in cases {
            XCTAssertEqual(MessageLength.isTooLong(text), isTooLong, name)
        }
    }
}
