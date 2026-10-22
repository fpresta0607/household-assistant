// What the Today card shows at one moment: the next thing still ahead first, two more at
// most, Today or Tonight over them, and the day's verse at the bottom. Worked out on the
// phone from the card its assistant last wrote, so it moves on by the phone's own clock as
// the day passes, offline too, without asking the gateway again (CFO notes section 21c).

import Foundation

struct TodayGlance: Equatable, Sendable {
    enum Heading: Equatable, Sendable {
        case today
        case tonight
    }

    /// One thing as the card says it.
    struct Line: Equatable, Sendable {
        let title: String
        let detail: String?
        /// "9:00", or "Sat 8:00" on another day. For something all day, nil today and the
        /// day's name on another.
        let time: String?
        let start: Date
        /// Whether it is over, or under way long enough to be no longer what is next.
        let isPast: Bool
    }

    let heading: Heading
    /// The next thing still ahead, or nil when only the verse is left.
    let next: Line?
    /// Up to two after it.
    let more: [Line]
    let verse: TodayCard.Verse?

    /// How long after it starts something is still what is next: a dentist at 9:00 is still
    /// what is on at 9:10.
    static let stillNext: TimeInterval = 15 * 60
    /// From this hour the card says Tonight.
    static let eveningHour = 17
    /// First opening from 5 AM is the morning's, even after a visit past midnight.
    static let morningHour = 5
    /// How many follow the next thing.
    static let mostMore = 2

    /// Nil when nothing is left to show: nothing ahead, and no verse for today.
    init?(card: TodayCard, at now: Date, calendar: Calendar) {
        let ahead = Self.lines(of: card, at: now, calendar: calendar).filter { !$0.isPast }
        // The morning's verse is the day's, so yesterday's never shows this morning.
        let verse = Self.isDay(card.day, of: now, calendar: calendar) ? card.verse : nil
        guard !ahead.isEmpty || verse != nil else {
            return nil
        }
        heading = calendar.component(.hour, from: now) >= Self.eveningHour ? .tonight : .today
        next = ahead.first
        more = Array(ahead.dropFirst().prefix(Self.mostMore))
        self.verse = verse
    }

    /// Everything in `card` as the card says it, the soonest first, what has gone by marked.
    static func lines(of card: TodayCard, at now: Date, calendar: Calendar) -> [Line] {
        card.items.compactMap { item -> Line? in
            guard let start = item.startDate else {
                return nil
            }
            let from = item.allDay ? calendar.startOfDay(for: start) : start
            return Line(
                title: item.title,
                detail: item.detail,
                time: label(start, isAllDay: item.allDay, at: now, calendar: calendar),
                start: from,
                isPast: end(of: item, from: from, calendar: calendar) <= now
            )
        }
        .sorted { $0.start < $1.start }
    }

    /// The next moment after `now` at which what the card shows changes: something stops
    /// being next, the evening comes, or the day ends.
    static func nextChange(of card: TodayCard, after now: Date, calendar: Calendar) -> Date? {
        let startOfToday = calendar.startOfDay(for: now)
        var moments = card.items.compactMap { item -> Date? in
            guard let start = item.startDate else {
                return nil
            }
            return end(of: item, from: item.allDay ? calendar.startOfDay(for: start) : start, calendar: calendar)
        }
        moments.append(contentsOf: [
            calendar.date(bySettingHour: morningHour, minute: 0, second: 0, of: now),
            calendar.date(bySettingHour: eveningHour, minute: 0, second: 0, of: now),
            calendar.date(byAdding: .day, value: 1, to: startOfToday),
        ].compactMap { $0 })
        return moments.filter { $0 > now }.min()
    }

    /// Whether `day`, as the gateway writes one, is the day `now` falls on.
    static func isDay(_ day: String, of now: Date, calendar: Calendar) -> Bool {
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        guard let year = parts.year, let month = parts.month, let dayNumber = parts.day else {
            return false
        }
        return day == String(format: "%04d-%02d-%02d", year, month, dayNumber)
    }

    /// Calendar arithmetic respects the phone's time zone and daylight-saving changes.
    static func morning(containing moment: Date, calendar: Calendar) -> Date {
        let today = calendar.date(bySettingHour: morningHour, minute: 0, second: 0, of: moment)!
        return moment >= today ? today : calendar.date(byAdding: .day, value: -1, to: today)!
    }

    /// When something stops being what is next: a while after it starts, or for something
    /// all day, when its day ends.
    private static func end(of item: TodayCard.Item, from start: Date, calendar: Calendar) -> Date {
        item.allDay ? calendar.date(byAdding: .day, value: 1, to: start) ?? start : start.addingTimeInterval(stillNext)
    }

    private static func label(_ start: Date, isAllDay: Bool, at now: Date, calendar: Calendar) -> String? {
        let locale = calendar.locale ?? .current
        let isToday = calendar.isDate(start, inSameDayAs: now)
        let weekday = start.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).weekday(.abbreviated))
        if isAllDay {
            return isToday ? nil : weekday
        }
        // The locale's own short time, "9:00" rather than "9:00 AM", as the card's lines are
        // short: the morning or afternoon is plain from the rest of the day around it.
        let time = start.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
            .replacingOccurrences(of: calendar.amSymbol, with: "")
            .replacingOccurrences(of: calendar.pmSymbol, with: "")
            .trimmingCharacters(in: .whitespaces)
        return isToday ? time : "\(weekday) \(time)"
    }
}
