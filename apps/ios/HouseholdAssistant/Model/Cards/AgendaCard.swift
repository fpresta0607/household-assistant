// A day, or a week, at a glance: each day as a calendar mark beside one row for each thing
// on it, the thing in bold and its time. The Sunday digest sends the coming week as one, and
// the Today card draws its day the same way (AgendaDayView).

import Foundation

struct AgendaCard: Decodable, Equatable, Sendable {
    /// One thing on a day: what it is, and when, as written, such as "9:00 AM"; nil all day.
    struct Event: Decodable, Equatable, Sendable {
        let title: String
        let time: String?
    }

    struct Day: Equatable, Sendable {
        let mark: CalendarMark
        let events: [Event]
    }

    /// The most days and things a card draws, past which it is refused rather than cut.
    static let mostDays = 7
    static let mostEvents = 12

    let title: String?
    let days: [Day]

    init(title: String?, days: [Day]) {
        self.title = title
        self.days = days
    }

    private enum CodingKeys: String, CodingKey {
        case title, days
    }

    private struct WrittenDay: Decodable {
        let date: String
        let events: [Event]
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        let written = try container.decode([WrittenDay].self, forKey: .days)
        guard !written.isEmpty, written.count <= Self.mostDays,
              written.allSatisfy({ !$0.events.isEmpty && $0.events.count <= Self.mostEvents }) else {
            throw DecodingError.dataCorruptedError(forKey: .days, in: container, debugDescription: "one to seven days, each with one to twelve things")
        }
        days = try written.map { day in
            guard let mark = CalendarMark(day: day.date) else {
                throw DecodingError.dataCorruptedError(forKey: .days, in: container, debugDescription: "a day is YYYY-MM-DD")
            }
            return Day(mark: mark, events: day.events)
        }
    }
}
