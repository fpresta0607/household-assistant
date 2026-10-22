// One thing an assistant's run changed, from the `did` list the household-app plugin keeps
// on its reply (did.js): an event added, moved, changed or deleted, a reminder set, moved,
// changed or deleted, the household cart changed, or an email drafted, with its title and
// when it is. The app shows each as a chip under the answer.
//
// The gateway writes a moment exact, in UTC, and a whole day, such as an all-day event's,
// as its date alone. One of a kind or a change this version does not know, or whose time
// does not read, is no change at all.

import Foundation

struct AssistantChange: Decodable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case event, reminder, list, message
    }

    enum Change: String, Sendable {
        case added, moved, changed, deleted, drafted
    }

    enum When: Equatable, Sendable {
        case moment(Date)
        /// A date with no time, on whatever calendar shows it.
        case day(DateComponents)
    }

    let kind: Kind
    let change: Change
    let title: String?
    let when: When?

    init(kind: Kind, change: Change, title: String? = nil, when: When? = nil) {
        self.kind = kind
        self.change = change
        self.title = title
        self.when = when
    }

    private enum CodingKeys: String, CodingKey {
        case kind, change, title, at, day
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard
            let kind = Kind(rawValue: try container.decode(String.self, forKey: .kind)),
            let change = Change(rawValue: try container.decode(String.self, forKey: .change))
        else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "a change this version does not know")
        }
        self.kind = kind
        self.change = change
        title = try container.decodeIfPresent(String.self, forKey: .title)
        if container.contains(.at) {
            when = .moment(try CardMoment.date(forKey: .at, in: container))
        } else if let day = try container.decodeIfPresent(String.self, forKey: .day) {
            let parts = day.split(separator: "-", omittingEmptySubsequences: false)
            guard
                parts.map(\.count) == [4, 2, 2],
                let year = Int(parts[0]),
                let month = Int(parts[1]),
                let date = Int(parts[2])
            else {
                throw DecodingError.dataCorruptedError(forKey: .day, in: container, debugDescription: "not a date such as 2026-10-17")
            }
            when = .day(DateComponents(year: year, month: month, day: date))
        } else {
            when = nil
        }
    }
}
