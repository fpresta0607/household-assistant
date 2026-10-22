// An event's when and where in one line, as its card and a drafted text that carries it
// show it.

import Foundation

extension EventCard {
    /// "Friday, October 16, 8:00 PM to 10:00 PM · Living room", in this phone's time zone,
    /// or without the day when a calendar page beside it already shows it.
    func details(isDayShown: Bool) -> String {
        let day = start.formatted(.dateTime.weekday(.wide).month(.wide).day())
        let startTime = start.formatted(date: .omitted, time: .shortened)
        var when = isDayShown ? "\(day), \(startTime)" : startTime
        if let end {
            let isSameDay = Calendar.current.isDate(start, inSameDayAs: end)
            let finish = isSameDay
                ? end.formatted(date: .omitted, time: .shortened)
                : end.formatted(.dateTime.weekday(.wide).hour().minute())
            when += " to \(finish)"
        }
        guard let location, !location.isEmpty else {
            return when
        }
        return "\(when) \u{00B7} \(location)"
    }
}
