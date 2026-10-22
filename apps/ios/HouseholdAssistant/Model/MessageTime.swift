// How a time reads above a run of bubbles: the day, which the room sets in bold, and the
// clock beside it. The day is "Today", "Yesterday", the weekday within the week, else
// the date.

import Foundation

enum MessageTime {
    enum Span: Equatable, Sendable {
        case today, yesterday, thisWeek, older
    }

    static func span(of date: Date, now: Date, calendar: Calendar) -> Span {
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        guard let days = calendar.dateComponents([.day], from: day, to: today).day else {
            return .older
        }
        switch days {
        case ...0: return .today
        case 1: return .yesterday
        case 2...6: return .thisWeek
        default: return .older
        }
    }

    /// The divider above a run of bubbles, as its day and its clock.
    static func divider(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> (day: String, time: String) {
        let time = date.formatted(date: .omitted, time: .shortened)
        switch span(of: date, now: now, calendar: calendar) {
        case .today:
            return ("Today", time)
        case .yesterday:
            return ("Yesterday", time)
        case .thisWeek:
            return (date.formatted(.dateTime.weekday(.wide)), time)
        case .older:
            let isThisYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            let day = isThisYear
                ? date.formatted(.dateTime.month(.abbreviated).day())
                : date.formatted(.dateTime.year().month(.abbreviated).day())
            return (day, time)
        }
    }
}
