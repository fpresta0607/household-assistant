// An Amazon order's progress, the buyer's alone: how far it has come along its steps, the
// day it arrives, and its number with all but the ends masked. The number and the day are
// there only when an email from Amazon gave them, and an order is never drawn in the
// family room (CardContent.isShown).

import Foundation

struct OrderCard: Decodable, Equatable, Sendable {
    enum Status: String, CaseIterable, Sendable {
        case ordered, shipped
        case outForDelivery = "out_for_delivery"
        case delivered
    }

    struct Step: Decodable, Equatable, Sendable {
        let label: String
        /// When it happened, when an email said.
        let at: Date?

        init(label: String, at: Date?) {
            self.label = label
            self.at = at
        }

        private enum CodingKeys: String, CodingKey {
            case label, at
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            label = try container.decode(String.self, forKey: .label)
            at = container.contains(.at) ? try CardMoment.date(forKey: .at, in: container) : nil
        }
    }

    let title: String
    /// How many items it holds.
    let items: Int
    let status: Status
    /// The day it arrives, as a day on the calendar rather than a moment.
    let arriving: DateComponents?
    /// The order number, masked.
    let order: String?
    /// One for each status, in order.
    let steps: [Step]

    private enum CodingKeys: String, CodingKey {
        case title, items, status, arriving, order, steps
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        items = try container.decode(Int.self, forKey: .items)
        guard let status = Status(rawValue: try container.decode(String.self, forKey: .status)) else {
            throw DecodingError.dataCorruptedError(forKey: .status, in: container, debugDescription: "not a status an order has")
        }
        self.status = status
        if let day = try container.decodeIfPresent(String.self, forKey: .arriving) {
            guard let arriving = Self.day(day) else {
                throw DecodingError.dataCorruptedError(forKey: .arriving, in: container, debugDescription: "a day is written 2026-10-16")
            }
            self.arriving = arriving
        } else {
            arriving = nil
        }
        order = try container.decodeIfPresent(String.self, forKey: .order)
        steps = try container.decode([Step].self, forKey: .steps)
        guard items >= 0, !steps.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .steps, in: container, debugDescription: "an order needs its steps")
        }
    }

    /// How many of its steps it has reached, the one it is at included. A step passed with
    /// no email to date it is reached all the same.
    var reached: Int {
        min(steps.count, (Status.allCases.firstIndex(of: status) ?? 0) + 1)
    }

    /// "2026-10-16" as that day, and nil for anything that is not a real one.
    private static func day(_ text: String) -> DateComponents? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard
            parts.map(\.count) == [4, 2, 2],
            parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
            let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        let components = DateComponents(year: year, month: month, day: day)
        // A day that does not exist, such as 30 February, comes back as another.
        guard let date = calendar.date(from: components) else {
            return nil
        }
        let read = calendar.dateComponents([.year, .month, .day], from: date)
        guard read.year == year, read.month == month, read.day == day else {
            return nil
        }
        return components
    }
}
