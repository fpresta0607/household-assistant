// The moments cards name: ISO 8601 with an offset, with or without fractions of a second,
// read as the same instant whatever the offset, and nothing else accepted.

import XCTest
@testable import HouseholdAssistant

final class CardMomentTests: XCTestCase {
    private struct Moment: Decodable {
        let at: Date

        private enum CodingKeys: String, CodingKey {
            case at
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            at = try CardMoment.date(forKey: .at, in: container)
        }
    }

    private func moment(_ text: String) throws -> Date {
        try JSONDecoder().decode(Moment.self, from: Data(#"{"at":"\#(text)"}"#.utf8)).at
    }

    func testAMomentWithAnOffsetIsTheSameInstantWhateverTheOffset() throws {
        let cases: [(text: String, seconds: TimeInterval)] = [
            ("2026-10-16T15:30:00-04:00", 1_792_179_000),
            ("2026-10-16T19:30:00Z", 1_792_179_000),
            ("2026-10-17T01:00:00+05:30", 1_792_179_000),
            ("2026-10-16T19:30:00.250Z", 1_792_179_000.25),
            ("2026-10-16T15:30:00.5-04:00", 1_792_179_000.5),
        ]
        for (text, seconds) in cases {
            XCTAssertEqual(try moment(text).timeIntervalSince1970, seconds, accuracy: 0.0005, text)
        }
    }

    func testAMomentWithoutAnOffsetOrNotInISO8601IsRefused() {
        let cases = [
            "2026-10-16T15:30:00",
            "2026-10-16 15:30:00Z",
            "2026-10-16",
            "tomorrow at 3",
            "",
        ]
        for text in cases {
            XCTAssertThrowsError(try moment(text), text)
        }
    }
}
