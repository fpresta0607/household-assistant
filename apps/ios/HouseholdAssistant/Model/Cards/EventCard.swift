// Something on a day: a title, when it starts and maybe ends, and where.

import Foundation

struct EventCard: Decodable, Equatable, Sendable {
    let title: String
    let start: Date
    let end: Date?
    let location: String?

    init(title: String, start: Date, end: Date?, location: String?) {
        self.title = title
        self.start = start
        self.end = end
        self.location = location
    }

    private enum CodingKeys: String, CodingKey {
        case title, start, end, location
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        start = try CardMoment.date(forKey: .start, in: container)
        if container.contains(.end), try !container.decodeNil(forKey: .end) {
            end = try CardMoment.date(forKey: .end, in: container)
        } else {
            end = nil
        }
        location = try container.decodeIfPresent(String.self, forKey: .location)
        if let end, end < start {
            throw DecodingError.dataCorruptedError(forKey: .end, in: container, debugDescription: "an event cannot end before it starts")
        }
    }

    /// What a calendar is given as the end: an hour after the start when the card names none.
    var calendarEnd: Date {
        end ?? start.addingTimeInterval(3600)
    }
}
