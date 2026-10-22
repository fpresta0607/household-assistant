// The Spend page's month: the household's total by the end of each day from the 1st to
// the month's last in date order, whatever order the days were listed in, the days still
// to come empty, today's point at the box's total, an axis from zero to just above it,
// and lines that add up to it.

import XCTest
@testable import HouseholdAssistant

final class SpendMonthTests: XCTestCase {
    /// The household's October up to the 15th: its total by the end of each day.
    private static let october = [2.31, 4.85, 6.20, 9.02, 11.14, 13.05, 16.62, 19.20, 20.71, 23.12, 26.30, 28.41, 31.67, 35.95, 38.40]
        .enumerated()
        .map { index, spent in SpendReport.Day(day: String(format: "2026-10-%02d", index + 1), spent: spent) }

    private func report(_ month: String = "2026-10", total: Double = 38.40, days: [SpendReport.Day] = SpendMonthTests.october) -> SpendReport {
        SpendReport(
            month: month,
            at: 1_792_101_000_000,
            total: total,
            days: days,
            lines: [
                SpendReport.Line(id: "corey", name: "Corey", amount: 24.10),
                SpendReport.Line(id: "denise", name: "Denise", amount: 11.85),
                SpendReport.Line(id: "other", name: "Other use of the key", amount: 2.45),
            ],
            resetsOn: "2026-11-01"
        )
    }

    func testDaysRunInDateOrderFromTheFirstToTheMonthsLastDay() throws {
        let months: [(month: String, name: String, length: Int)] = [
            ("2026-02", "February", 28),
            ("2028-02", "February", 29),
            // A century is a leap year only every fourth one.
            ("2100-02", "February", 28),
            ("2026-04", "April", 30),
            ("2026-10", "October", 31),
        ]
        for (month, name, length) in months {
            // Arrange
            let given = report(month, total: 0, days: [])

            // Act
            let spend = try XCTUnwrap(SpendMonth(given), month)

            // Assert
            XCTAssertEqual(spend.days.map(\.id), (1...length).map { month + String(format: "-%02d", $0) }, month)
            XCTAssertEqual(spend.days.first?.words, "\(name) 1", month)
            XCTAssertEqual(spend.days.last?.words, "\(name) \(length)", month)
        }
    }

    func testDaysStillToComeAreEmptyAfterToday() throws {
        // Act
        let spend = try XCTUnwrap(SpendMonth(report()))

        // Assert
        XCTAssertEqual(spend.days.count, 31)
        XCTAssertEqual(spend.days.prefix(15).map(\.spent), Self.october.map { Optional($0.spent) })
        XCTAssertEqual(spend.days.suffix(16).map(\.spent), [Double?](repeating: nil, count: 16))
    }

    func testDaysListedOutOfOrderStillRunFromTheFirst() throws {
        // Arrange
        let shuffled = [9, 2, 14, 0, 7, 12, 4, 1, 10, 13, 6, 3, 11, 5, 8].map { Self.october[$0] }
        XCTAssertNotEqual(shuffled.map(\.day), Self.october.map(\.day), "the days are really out of order")

        // Act
        let spend = try XCTUnwrap(SpendMonth(report(days: shuffled)))

        // Assert
        XCTAssertEqual(spend.days.prefix(15).map(\.id), Self.october.map(\.day))
        XCTAssertEqual(spend.days.prefix(15).map(\.spent), Self.october.map { Optional($0.spent) })
    }

    func testTodaysPointIsTheMonthsTotalAndTheLineNeverGoesDown() throws {
        // Act
        let spend = try XCTUnwrap(SpendMonth(report()))

        // Assert
        let drawn = spend.days.compactMap(\.spent)
        XCTAssertEqual(spend.total, 38.40)
        XCTAssertEqual(drawn.last, spend.total)
        XCTAssertEqual(drawn, drawn.sorted())
    }

    func testTheLinesAddUpToTheTotalToTheCent() {
        // Act
        let given = report()

        // Assert
        let cents = given.lines.map { Int(($0.amount * 100).rounded()) }.reduce(0, +)
        XCTAssertEqual(cents, Int((given.total * 100).rounded()))
        XCTAssertEqual(given.lines.filter(\.isAssistant).map(\.name), ["Corey", "Denise"])
    }

    func testTheAxisEndsJustAboveTheTotal() {
        let cases: [(total: Double, top: Double)] = [
            (32.56, 35),
            (30, 35),
            (38.40, 40),
            (9.50, 10),
            (0.07, 0.5),
            (0, 0.5),
            (99.90, 100),
            (120, 150),
        ]
        for (total, top) in cases {
            // Act
            let axis = SpendMonth.top(above: total)

            // Assert
            XCTAssertEqual(axis, top, accuracy: 0.000_001, "\(total)")
            XCTAssertGreaterThan(axis, total, "\(total)")
        }
    }

    func testAReportWithoutAMonthHasNoGraph() {
        for month in ["", "October", "2026", "2026-10-07"] {
            XCTAssertNil(SpendMonth(report(month)), month)
        }
    }

    func testATapShowsTheDayItLandsOnWithItsDateAndTotalByThen() throws {
        // Arrange
        let spend = try XCTUnwrap(SpendMonth(report()))

        // Act
        let shown = spend.selecting("2026-10-07", showing: nil)

        // Assert
        XCTAssertEqual(shown, "2026-10-07")
        XCTAssertEqual(spend.point(shown)?.words, "October 7")
        XCTAssertEqual(spend.point(shown)?.spent, 16.62)
    }

    func testDraggingOnToAnotherDayShowsThatDay() throws {
        // Arrange
        let spend = try XCTUnwrap(SpendMonth(report()))

        // Act
        let shown = spend.selecting("2026-10-08", showing: "2026-10-07")

        // Assert
        XCTAssertEqual(shown, "2026-10-08")
    }

    func testATapOnTheDayAlreadyShownKeepsItsAmountVisible() throws {
        // Arrange
        let spend = try XCTUnwrap(SpendMonth(report()))

        // Act
        let shown = spend.selecting("2026-10-07", showing: "2026-10-07")

        // Assert
        XCTAssertEqual(shown, "2026-10-07")
        XCTAssertEqual(spend.point(shown)?.spent, 16.62)
    }

    func testTheLastPlottedDayStaysSelectedAndUsesTheRefreshedTotal() throws {
        let original = try XCTUnwrap(SpendMonth(report()))
        let selected = original.selecting("2026-10-15", showing: nil)
        XCTAssertEqual(original.point(selected)?.spent, 38.40)
        XCTAssertEqual(original.selecting("2026-10-15", showing: selected), selected)

        var days = Self.october
        days[14] = SpendReport.Day(day: "2026-10-15", spent: 40.12)
        let refreshed = try XCTUnwrap(SpendMonth(report(total: 40.12, days: days)))
        XCTAssertEqual(refreshed.point(selected)?.spent, 40.12)
        XCTAssertEqual(refreshed.point(selected)?.spent, refreshed.total)
    }

    func testAZeroSpendDayIsSelectableAndAnOldMonthsSelectionIsNot() throws {
        let zero = try XCTUnwrap(SpendMonth(report(total: 0, days: [.init(day: "2026-10-01", spent: 0)])))
        XCTAssertEqual(zero.point(zero.selecting("2026-10-01", showing: nil))?.spent, 0)
        XCTAssertNil(zero.point("2026-09-30"))
    }

    func testFreshnessUsesTheSourcesTimestampRatherThanWhenThePageWasOpened() {
        let given = report()
        XCTAssertEqual(given.updatedAt.timeIntervalSince1970, 1_792_101_000)
        XCTAssertFalse(given.isStale(at: given.updatedAt.addingTimeInterval(20 * 60)))
        XCTAssertTrue(given.isStale(at: given.updatedAt.addingTimeInterval(20 * 60 + 1)))
    }

    func testADayStillToComeHasNoPointToShow() throws {
        // Arrange
        let spend = try XCTUnwrap(SpendMonth(report()))

        for shown in [nil, "2026-10-07"] {
            // Act
            let next = spend.selecting("2026-10-20", showing: shown)

            // Assert
            XCTAssertNil(next, shown ?? "none shown")
        }
        XCTAssertNil(spend.point("2026-10-20"))
        XCTAssertNil(spend.point(nil))
    }
}
