// The household's month as the Spend page draws it: its total by the end of each day,
// from the 1st to the month's last in date order, whatever order the days were listed
// in, on an axis from zero to just above the month's total. The box lists the 1st
// through today, so a day it has not listed is still to come and keeps its place with
// nothing drawn, and the line stops at today.

import Foundation

struct SpendMonth: Equatable, Sendable {
    struct Day: Equatable, Sendable, Identifiable {
        /// `2026-10-07`, as the box names the day.
        let id: String
        /// "October 7", as the page says it when the day is tapped.
        let words: String
        /// The month's total by the end of that day, or nil for a day still to come.
        let spent: Double?
    }

    /// The 1st first and the month's last day last.
    let days: [Day]
    /// The box's own figure, which today's point reaches.
    let total: Double
    /// Where the graph's axis ends, just above the total.
    let top: Double

    /// Nil when the report's month is not one like `2026-10`. Its length, 28 to 31 days,
    /// is the Gregorian calendar's.
    init?(_ report: SpendReport) {
        let parts = report.month.split(separator: "-").compactMap { Int($0) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        guard
            parts.count == 2,
            let monthName = report.monthName,
            let first = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: 1)),
            let length = calendar.range(of: .day, in: .month, for: first)?.count
        else {
            return nil
        }
        var spent: [String: Double] = [:]
        for day in report.days {
            spent[day.day] = day.spent
        }
        days = (1...length).map { number in
            let id = report.month + String(format: "-%02d", number)
            return Day(id: id, words: "\(monthName) \(number)", spent: spent[id])
        }
        total = report.total
        top = Self.top(above: report.total)
    }

    /// The next step above `total`, a step being half its power of ten and never under
    /// 50 cents: $32.56 tops out at $35, $30 at $35 too, and $9.50 at $10.
    static func top(above total: Double) -> Double {
        guard total > 0 else {
            return 0.5
        }
        let step = max(0.5, pow(10, floor(log10(total))) / 2)
        return (floor(total / step) + 1) * step
    }

    /// The day with a point at `id`: nil for a day still to come, or for no day.
    func point(_ id: String?) -> Day? {
        days.first { $0.id == id && $0.spent != nil }
    }

    /// Re-tapping a point or crossing it again while dragging keeps its amount visible.
    /// The page has an explicit way back to the month total. Days still to come have
    /// no spend and must never display a fabricated zero.
    func selecting(_ id: String, showing shown: String?) -> String? {
        point(id)?.id
    }
}

