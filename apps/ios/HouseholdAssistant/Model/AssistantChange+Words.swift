// What the chip for one thing an assistant's run changed says and shows: "Added Movie night,
// Fri 7:00 PM" by a calendar, "Reminder set, 3:45 PM" by a bell, and where a tap on it goes,
// where it can go anywhere: the event's day in Calendar, or the reminder as its card.

import Foundation

extension AssistantChange {
    /// Where a tap on the chip goes.
    enum Destination: Equatable, Sendable {
        /// Calendar, opened on the event's day.
        case calendar(URL)
        case reminder(ReminderCard)
    }

    /// The chip's words, its time in `calendar`'s zone and locale, with `now` saying which
    /// day is today.
    func words(now: Date, calendar: Calendar) -> String {
        let when = self.when.flatMap { Self.spoken($0, now: now, calendar: calendar) }
        switch (kind, change) {
        case (.event, .added):
            return "Added \(title ?? "an event")" + (when.map { ", \($0)" } ?? "")
        case (.event, .moved):
            return "Moved \(title ?? "an event")" + (when.map { " to \($0)" } ?? "")
        case (.event, .deleted):
            return "Deleted \(title ?? "an event")"
        case (.event, _):
            return title.map { "Changed \($0)" } ?? "Changed the calendar"
        case (.reminder, .added):
            return "Reminder set" + (when.map { ", \($0)" } ?? "")
        case (.reminder, .moved):
            return "Reminder moved" + (when.map { " to \($0)" } ?? "")
        case (.reminder, .deleted):
            return "Reminder deleted"
        case (.reminder, _):
            return "Reminder changed"
        case (.list, .added):
            return title.map { "Added \($0) to the cart" } ?? "Added to the cart"
        case (.list, .deleted):
            return "Took an item off the cart"
        case (.list, _):
            return "Changed the cart"
        case (.message, _):
            return "Email drafted" + (title.map { ", \($0)" } ?? "")
        }
    }

    /// The SF Symbol beside the words.
    var symbol: String {
        switch (kind, change) {
        case (.event, .added):
            return "calendar.badge.plus"
        case (.event, .moved):
            return "calendar.badge.clock"
        case (.event, .deleted):
            return "calendar.badge.minus"
        case (.event, _):
            return "calendar"
        case (.reminder, .deleted):
            return "bell.slash"
        case (.reminder, _):
            return "bell"
        case (.list, .added):
            return "cart.badge.plus"
        case (.list, .deleted):
            return "cart.badge.minus"
        case (.list, _):
            return "cart"
        case (.message, _):
            return "envelope"
        }
    }

    /// Calendar on the day of an event that is still there, and the card of a reminder set
    /// or moved to a moment. Nil for anything else, whose chip is no button.
    func destination(calendar: Calendar) -> Destination? {
        switch (kind, change, when) {
        case (.event, .deleted, _), (.event, _, nil):
            return nil
        case (.event, _, .moment(let date)?):
            return Self.calendarLink(date)
        case (.event, _, .day(let day)?):
            return calendar.date(from: day).flatMap(Self.calendarLink)
        case (.reminder, .added, .moment(let date)?), (.reminder, .moved, .moment(let date)?):
            return .reminder(ReminderCard(text: title ?? "Reminder", at: date))
        default:
            return nil
        }
    }

    /// Calendar's own link to a day, which takes the moment in seconds since 2001.
    private static func calendarLink(_ date: Date) -> Destination? {
        URL(string: "calshow:\(Int(date.timeIntervalSinceReferenceDate))").map(Destination.calendar)
    }

    /// "3:45 PM" today, "Fri 7:00 PM" in the coming week, else "Oct 24, 8:00 AM"; a whole
    /// day as "today", "Sat" or "Oct 24".
    private static func spoken(_ when: When, now: Date, calendar: Calendar) -> String? {
        let style = Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
        let date: Date
        let time: String?
        switch when {
        case .moment(let moment):
            date = moment
            time = moment.formatted(Date.FormatStyle(
                date: .omitted,
                time: .shortened,
                locale: calendar.locale ?? .current,
                calendar: calendar,
                timeZone: calendar.timeZone
            ))
        case .day(let day):
            guard let start = calendar.date(from: day) else {
                return nil
            }
            date = start
            time = nil
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? -1
        switch days {
        case 0:
            return time ?? "today"
        case 1...6:
            let weekday = date.formatted(style.weekday(.abbreviated))
            return time.map { "\(weekday) \($0)" } ?? weekday
        default:
            let day = date.formatted(style.month(.abbreviated).day())
            return time.map { "\(day), \($0)" } ?? day
        }
    }
}
