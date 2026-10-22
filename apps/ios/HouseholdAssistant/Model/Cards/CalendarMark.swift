// A day as the Calendar app's icon draws it, which the Overlord asked the day snapshot to
// wear: the month in three capital letters over the day's number, large. The day snapshot
// (the Today card) and the agenda card (the Sunday digest's week) both lead with it.

import Foundation

struct CalendarMark: Equatable, Sendable {
    static let months = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]

    /// "OCT".
    let month: String
    /// "22".
    let day: String

    /// The mark for a day as the gateway writes one, YYYY-MM-DD, or nil for anything else.
    init?(day text: String) {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              Int(parts[0]) != nil, let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day) else {
            return nil
        }
        self.month = Self.months[month - 1]
        self.day = String(day)
    }

    /// The mark for the day `date` falls on in `calendar`.
    init(date: Date, calendar: Calendar) {
        let parts = calendar.dateComponents([.month, .day], from: date)
        month = Self.months[(parts.month ?? 1) - 1]
        day = String(parts.day ?? 1)
    }
}
