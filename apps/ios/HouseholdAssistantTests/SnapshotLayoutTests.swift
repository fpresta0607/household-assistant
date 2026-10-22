// The day snapshot's layout the Overlord asked for on 22 October: a calendar mark, the month
// in three letters over the day's number, and one row for each thing, in bold with its time.
// The Today card's day and the agenda card the Sunday digest sends are both drawn from what
// is checked here. Every event is made up.

import XCTest
@testable import HouseholdAssistant

final class SnapshotLayoutTests: XCTestCase {
    /// The household: Chicago in October, as a fixed offset, read in American English.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: -5 * 3600)!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    private func card(_ json: String) -> MessageSegment? {
        StewardCardParser.segments(in: "```steward-card\n\(json)\n```", isStreaming: false).first
    }

    func testACalendarMarkIsTheMonthInThreeLettersOverTheDaysNumber() {
        XCTAssertEqual(CalendarMark(day: "2026-10-22"), CalendarMark(date: Date(timeIntervalSince1970: 1_792_688_400), calendar: calendar))
        XCTAssertEqual(CalendarMark(day: "2026-10-22")?.month, "OCT")
        XCTAssertEqual(CalendarMark(day: "2026-10-22")?.day, "22")
        XCTAssertEqual(CalendarMark(day: "2027-01-05")?.day, "5", "no leading zero, as the Calendar icon writes it")
        for written in ["2026-13-01", "2026-10-32", "Oct 22", "2026-1-5", ""] {
            XCTAssertNil(CalendarMark(day: written), written)
        }
    }

    func testTheAgendaCardReadsEachDayAsItsMarkAndOneRowForEachThing() throws {
        // Arrange
        let json = #"""
            {"type":"agenda","title":"The week ahead","skill":"calendar","days":[
            {"date":"2026-10-26","events":[{"title":"Dentist","time":"9:00 AM"},{"title":"Piano lesson","time":"4:30 PM"}]},
            {"date":"2026-10-28","events":[{"title":"School picture day"}]}]}
            """#

        // Act
        guard case .card(let read)? = card(json), case .agenda(let agenda) = read.content else {
            return XCTFail("not read as an agenda card")
        }

        // Assert
        XCTAssertEqual(read.skill, .calendar)
        XCTAssertEqual(agenda.title, "The week ahead")
        XCTAssertEqual(agenda.days.map { "\($0.mark.month) \($0.mark.day)" }, ["OCT 26", "OCT 28"])
        XCTAssertEqual(agenda.days[0].events, [AgendaCard.Event(title: "Dentist", time: "9:00 AM"), AgendaCard.Event(title: "Piano lesson", time: "4:30 PM")])
        XCTAssertEqual(agenda.days[1].events, [AgendaCard.Event(title: "School picture day", time: nil)], "all day has no time")
        XCTAssertEqual(
            MessagePlainText.text(of: "```steward-card\n\(json)\n```", calendar: calendar),
            "The week ahead\nOCT 26\nDentist, 9:00 AM\nPiano lesson, 4:30 PM\nOCT 28\nSchool picture day, all day"
        )
    }

    func testAnAgendaWithADayThatIsNoDayOrNothingOnItIsNoCard() {
        for json in [
            #"{"type":"agenda","days":[]}"#,
            #"{"type":"agenda","days":[{"date":"2026-10-26","events":[]}]}"#,
            #"{"type":"agenda","days":[{"date":"Monday","events":[{"title":"Dentist"}]}]}"#,
        ] {
            if case .card? = card(json) {
                XCTFail("read as a card: \(json)")
            }
        }
    }

    func testTheTodayCardsDayIsTheNextThingsMarkAndARowForTheNextAndTwoMore() throws {
        // Arrange: Thursday 15 October 2026, 6:45 in the morning.
        let today = try JSONDecoder().decode(TodayCard.self, from: Data(#"""
            {"day":"2026-10-15","at":1792064700000,"items":[
            {"start":"2026-10-15T07:45:00-05:00","title":"School drop off","detail":"Leave by 7:30"},
            {"start":"2026-10-15T09:00:00-05:00","title":"Dentist"},
            {"start":"2026-10-15T12:30:00-05:00","title":"Lunch with a friend"},
            {"start":"2026-10-15T17:45:00-05:00","title":"Soccer pickup"}]}
            """#.utf8))
        let now = Date(timeIntervalSince1970: 1_792_040_400 + 6 * 3_600 + 45 * 60)
        let glance = try XCTUnwrap(TodayGlance(card: today, at: now, calendar: calendar))

        // Act
        let day = glance.agendaDay(at: now, calendar: calendar)

        // Assert
        XCTAssertEqual(day.mark, CalendarMark(day: "2026-10-15"))
        XCTAssertEqual(day.events.map(\.title), ["School drop off", "Dentist", "Lunch with a friend"])
        XCTAssertEqual(day.events.map(\.time), glance.more.reduce([glance.next?.time]) { $0 + [$1.time] })
        XCTAssertTrue(day.events.allSatisfy { $0.time != nil })
    }
}
