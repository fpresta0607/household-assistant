// What an assistant's answer changed, as the gateway keeps it on the reply (did.js in the
// household-app plugin) and as the chips under the answer say it: the entry's `did` list
// decoded, an item this version cannot read left out, the chip's words and glyph, and where
// a tap on it goes.

import Foundation
import XCTest
@testable import HouseholdAssistant

final class AssistantChangeTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: -5 * 3600)!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    /// Thursday 15 October 2026 at 10:00 in the calendar's zone.
    private static let now = Date(timeIntervalSince1970: 1_792_076_400)

    private func at(daysAfter days: Int, hour: Int, minute: Int = 0) -> Date {
        let morning = calendar.startOfDay(for: Self.now)
        return calendar.date(byAdding: DateComponents(day: days, hour: hour, minute: minute), to: morning)!
    }

    /// "7:00 PM" as this calendar's locale writes a time, whose space before PM differs
    /// between Foundation's versions.
    private func clock(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: calendar.locale!, calendar: calendar, timeZone: calendar.timeZone))
    }

    private func entry(did: JSONValue?) throws -> RoomEntry {
        var members: [String: JSONValue] = [
            "id": .string("a-1"), "rev": .number(7), "kind": .string("message"),
            "conversation": .string("direct"), "author": .string("corey"),
            "at": .number(1_792_076_400_000), "origin": .string("local"),
            "text": .string("Done."), "media": .array([]), "replyTo": .null,
        ]
        if let did {
            members["did"] = did
        }
        return try JSONValue.object(members).decoded(as: RoomEntry.self)
    }

    // MARK: - Decoding

    func testAReplysDidListDecodesEachChangeWithItsTitleAndWhen() throws {
        // Arrange: the list as did.js writes it.
        let did: JSONValue = .array([
            .object(["kind": .string("event"), "change": .string("added"), "title": .string("Movie night"), "at": .string("2026-10-17T00:00:00.000Z")]),
            .object(["kind": .string("event"), "change": .string("added"), "title": .string("Fall fair"), "day": .string("2026-10-17")]),
            .object(["kind": .string("reminder"), "change": .string("deleted")]),
        ])

        // Act
        let changes = try entry(did: did).did

        // Assert
        XCTAssertEqual(changes, [
            AssistantChange(kind: .event, change: .added, title: "Movie night", when: .moment(Date(timeIntervalSince1970: 1_792_195_200))),
            AssistantChange(kind: .event, change: .added, title: "Fall fair", when: .day(DateComponents(year: 2026, month: 10, day: 17))),
            AssistantChange(kind: .reminder, change: .deleted),
        ])
    }

    func testAChangeThisVersionCannotReadIsLeftOutAndTheMessageStays() throws {
        // Arrange
        let did: JSONValue = .array([
            .object(["kind": .string("parcel"), "change": .string("added")]),
            .object(["kind": .string("event"), "change": .string("teleported")]),
            .object(["kind": .string("reminder"), "change": .string("added"), "at": .string("tomorrow")]),
            .object(["kind": .string("event"), "change": .string("added"), "day": .string("17 October")]),
            .string("not a change"),
            .object(["kind": .string("list"), "change": .string("added"), "title": .string("Milk")]),
        ])

        // Act
        let kept = try entry(did: did)

        // Assert
        XCTAssertEqual(kept.did, [AssistantChange(kind: .list, change: .added, title: "Milk")])
        XCTAssertEqual(kept.text, "Done.")
    }

    func testAnEntryWithNoListOrABrokenOneHasNoChanges() throws {
        XCTAssertEqual(try entry(did: nil).did, [])
        XCTAssertEqual(try entry(did: .string("not a list")).did, [])
        XCTAssertEqual(try entry(did: .null).did, [])
    }

    func testAKeptMessageCarriesItsEntrysChanges() throws {
        let message = RoomMessage(try entry(did: .array([.object(["kind": .string("message"), "change": .string("drafted")])])))
        XCTAssertEqual(message.did, [AssistantChange(kind: .message, change: .drafted)])
    }

    // MARK: - The chip's words

    func testEachChangeSaysWhatChangedAndWhen() {
        let friday = at(daysAfter: 1, hour: 19)
        let tuesday = at(daysAfter: 5, hour: 15)
        let thisAfternoon = at(daysAfter: 0, hour: 15, minute: 45)
        let inNineDays = at(daysAfter: 9, hour: 8)
        let cases: [(AssistantChange, String)] = [
            (AssistantChange(kind: .event, change: .added, title: "Movie night", when: .moment(friday)), "Added Movie night, Fri \(clock(friday))"),
            (AssistantChange(kind: .event, change: .added, title: "Fall fair", when: .day(DateComponents(year: 2026, month: 10, day: 24))), "Added Fall fair, Oct 24"),
            (AssistantChange(kind: .event, change: .added), "Added an event"),
            (AssistantChange(kind: .event, change: .moved, title: "Dentist", when: .moment(tuesday)), "Moved Dentist to Tue \(clock(tuesday))"),
            (AssistantChange(kind: .event, change: .moved), "Moved an event"),
            (AssistantChange(kind: .event, change: .changed, title: "Dentist"), "Changed Dentist"),
            (AssistantChange(kind: .event, change: .changed), "Changed the calendar"),
            (AssistantChange(kind: .event, change: .deleted, title: "Movie night"), "Deleted Movie night"),
            (AssistantChange(kind: .reminder, change: .added, title: "Leave for pickup", when: .moment(thisAfternoon)), "Reminder set, \(clock(thisAfternoon))"),
            (AssistantChange(kind: .reminder, change: .added, title: "Bins out"), "Reminder set"),
            (AssistantChange(kind: .reminder, change: .moved, when: .moment(inNineDays)), "Reminder moved to Oct 24, \(clock(inNineDays))"),
            (AssistantChange(kind: .reminder, change: .changed), "Reminder changed"),
            (AssistantChange(kind: .reminder, change: .deleted), "Reminder deleted"),
            (AssistantChange(kind: .list, change: .added, title: "Birthday candles"), "Added Birthday candles to the cart"),
            (AssistantChange(kind: .list, change: .changed), "Changed the cart"),
            (AssistantChange(kind: .list, change: .deleted), "Took an item off the cart"),
            (AssistantChange(kind: .message, change: .drafted, title: "Field trip form"), "Email drafted, Field trip form"),
            (AssistantChange(kind: .message, change: .drafted), "Email drafted"),
        ]
        for (change, words) in cases {
            XCTAssertEqual(change.words(now: Self.now, calendar: calendar), words)
        }
        XCTAssertTrue(clock(friday).hasPrefix("7:00"), clock(friday))
        XCTAssertTrue(clock(friday).hasSuffix("PM"), clock(friday))
    }

    func testADayIsTodayThisWeekOrADate() {
        let today = AssistantChange(kind: .event, change: .added, title: "Bake sale", when: .day(DateComponents(year: 2026, month: 10, day: 15)))
        let saturday = AssistantChange(kind: .event, change: .added, title: "Bake sale", when: .day(DateComponents(year: 2026, month: 10, day: 17)))
        XCTAssertEqual(today.words(now: Self.now, calendar: calendar), "Added Bake sale, today")
        XCTAssertEqual(saturday.words(now: Self.now, calendar: calendar), "Added Bake sale, Sat")
    }

    func testEachChangeHasItsGlyph() {
        XCTAssertEqual(AssistantChange(kind: .event, change: .added).symbol, "calendar.badge.plus")
        XCTAssertEqual(AssistantChange(kind: .event, change: .moved).symbol, "calendar.badge.clock")
        XCTAssertEqual(AssistantChange(kind: .event, change: .changed).symbol, "calendar")
        XCTAssertEqual(AssistantChange(kind: .event, change: .deleted).symbol, "calendar.badge.minus")
        XCTAssertEqual(AssistantChange(kind: .reminder, change: .added).symbol, "bell")
        XCTAssertEqual(AssistantChange(kind: .reminder, change: .deleted).symbol, "bell.slash")
        XCTAssertEqual(AssistantChange(kind: .list, change: .added).symbol, "cart.badge.plus")
        XCTAssertEqual(AssistantChange(kind: .list, change: .deleted).symbol, "cart.badge.minus")
        XCTAssertEqual(AssistantChange(kind: .list, change: .changed).symbol, "cart")
        XCTAssertEqual(AssistantChange(kind: .message, change: .drafted).symbol, "envelope")
    }

    // MARK: - Where a tap goes

    func testAnEventOpensItsDayInCalendarAndAReminderItsCard() throws {
        // Arrange
        let friday = at(daysAfter: 1, hour: 19)
        let added = AssistantChange(kind: .event, change: .added, title: "Movie night", when: .moment(friday))
        let allDay = AssistantChange(kind: .event, change: .added, title: "Fall fair", when: .day(DateComponents(year: 2026, month: 10, day: 17)))
        let reminder = AssistantChange(kind: .reminder, change: .added, title: "Leave for pickup", when: .moment(friday))
        let saturday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 17)))

        // Act and assert
        XCTAssertEqual(added.destination(calendar: calendar), .calendar(URL(string: "calshow:\(Int(friday.timeIntervalSinceReferenceDate))")!))
        XCTAssertEqual(allDay.destination(calendar: calendar), .calendar(URL(string: "calshow:\(Int(saturday.timeIntervalSinceReferenceDate))")!))
        XCTAssertEqual(reminder.destination(calendar: calendar), .reminder(ReminderCard(text: "Leave for pickup", at: friday)))
    }

    func testWhatHasNowhereToOpenIsNoButton() {
        let nowhere = [
            AssistantChange(kind: .event, change: .deleted, title: "Movie night", when: .moment(Self.now)),
            AssistantChange(kind: .event, change: .changed),
            AssistantChange(kind: .reminder, change: .added, title: "Bins out"),
            AssistantChange(kind: .reminder, change: .deleted, when: .moment(Self.now)),
            AssistantChange(kind: .list, change: .added, title: "Milk"),
            AssistantChange(kind: .message, change: .drafted, title: "Field trip form"),
        ]
        for change in nowhere {
            XCTAssertNil(change.destination(calendar: calendar), "\(change)")
        }
    }
}
