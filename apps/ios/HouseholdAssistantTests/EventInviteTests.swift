// The calendar file a drafted text carries for an event: one event in iCalendar's form, its
// times in UTC, an hour long when it names no end, its words escaped, its long lines folded
// without splitting a character, CRLF throughout, and a plain file name.

import XCTest
@testable import HouseholdAssistant

final class EventInviteTests: XCTestCase {
    private func date(_ iso: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: iso))
    }

    private func text(of event: EventCard) throws -> String {
        let data = EventInvite.file(for: event, uid: "u-1@steward.invalid", stamp: try date("2026-10-17T19:00:00Z"))
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    func testAnEventIsOneCalendarEventInUTC() throws {
        // Arrange
        let event = EventCard(
            title: "Movie night",
            start: try date("2026-10-23T20:00:00-04:00"),
            end: try date("2026-10-23T22:00:00-04:00"),
            location: "Living room"
        )

        // Act
        let file = try text(of: event)

        // Assert
        XCTAssertEqual(file, [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//Steward AI//Drafted text//EN",
            "METHOD:PUBLISH",
            "BEGIN:VEVENT",
            "UID:u-1@steward.invalid",
            "DTSTAMP:20261017T190000Z",
            "DTSTART:20261024T000000Z",
            "DTEND:20261024T020000Z",
            "SUMMARY:Movie night",
            "LOCATION:Living room",
            "END:VEVENT",
            "END:VCALENDAR",
        ].joined(separator: "\r\n") + "\r\n")
    }

    func testWithNoEndItLastsAnHourAndWithNoPlaceItNamesNone() throws {
        // Arrange
        let event = EventCard(title: "Dentist", start: try date("2026-10-23T15:30:00Z"), end: nil, location: nil)

        // Act
        let file = try text(of: event)

        // Assert
        XCTAssertTrue(file.contains("\r\nDTEND:20261023T163000Z\r\n"), file)
        XCTAssertFalse(file.contains("LOCATION"), file)
    }

    func testItsWordsAreEscaped() throws {
        // Arrange
        let event = EventCard(title: "Dinner, drinks; then \\ home", start: try date("2026-10-23T23:00:00Z"), end: nil, location: "Our place\nback door")

        // Act
        let file = try text(of: event)

        // Assert
        XCTAssertTrue(file.contains("\r\nSUMMARY:Dinner\\, drinks\\; then \\\\ home\r\n"), file)
        XCTAssertTrue(file.contains("\r\nLOCATION:Our place\\nback door\r\n"), file)
    }

    func testALongLineIsFoldedAt75BytesWithoutSplittingACharacter() throws {
        let titles = [String(repeating: "a", count: 160), String(repeating: "é", count: 90), String(repeating: "🎬", count: 40)]
        for title in titles {
            // Arrange
            let event = EventCard(title: title, start: try date("2026-10-23T23:00:00Z"), end: nil, location: nil)

            // Act
            let file = try text(of: event)

            // Assert
            let lines = file.components(separatedBy: "\r\n")
            XCTAssertTrue(lines.allSatisfy { $0.utf8.count <= 75 }, title)
            XCTAssertTrue(file.replacingOccurrences(of: "\r\n ", with: "").contains("\r\nSUMMARY:\(title)\r\n"), title)
        }
    }

    func testItsFileIsNamedForTheEvent() throws {
        let cases = [
            ("Movie night", "Movie night.ics"),
            ("Dinner/at: 8?", "Dinnerat 8.ics"),
            ("  Soccer - practice  ", "Soccer - practice.ics"),
            ("???", "Event.ics"),
        ]
        for (title, name) in cases {
            let event = EventCard(title: title, start: try date("2026-10-23T23:00:00Z"), end: nil, location: nil)
            XCTAssertEqual(EventInvite.fileName(for: event), name, title)
        }
    }
}
