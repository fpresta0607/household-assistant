// How long a person shares where they are before it stops by itself: an hour, until
// tonight, or always, which is until they stop it.

import Foundation

enum LocationSpan: String, Codable, CaseIterable, Sendable {
    case hour, tonight, always

    var title: String {
        switch self {
        case .hour:
            return "For an hour"
        case .tonight:
            return "Until tonight"
        case .always:
            return "Always"
        }
    }

    /// When sharing that starts at `start` ends: an hour on, midnight that night where the
    /// phone is, or never.
    func end(from start: Date, calendar: Calendar) -> Date? {
        switch self {
        case .hour:
            return start.addingTimeInterval(3600)
        case .tonight:
            return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: start))
        case .always:
            return nil
        }
    }
}
