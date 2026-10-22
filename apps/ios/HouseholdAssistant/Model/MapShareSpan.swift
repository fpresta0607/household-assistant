// How long a map a person shares in a chat keeps moving: not at all, 15 minutes, an hour,
// or until the end of the day, as the composer's plus offers it.

import Foundation

enum MapShareSpan: String, CaseIterable, Identifiable, Sendable {
    case once, quarterHour, hour, endOfDay

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .once:
            return "Once"
        case .quarterHour:
            return "For 15 minutes"
        case .hour:
            return "For 1 hour"
        case .endOfDay:
            return "Until the end of the day"
        }
    }

    /// When a map shared at `start` stops moving: nil for once, midnight that night where
    /// the phone is for the end of the day.
    func until(from start: Date, calendar: Calendar) -> Date? {
        switch self {
        case .once:
            return nil
        case .quarterHour:
            return start.addingTimeInterval(15 * 60)
        case .hour:
            return start.addingTimeInterval(3600)
        case .endOfDay:
            return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: start))
        }
    }
}
