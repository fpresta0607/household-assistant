// The month a spend report covers and the day it starts again, as the Spend page says
// them: "October", "November 1".

import Foundation

extension SpendReport {
    var monthName: String? {
        Self.date(month + "-01").map { $0.formatted(Self.style.month(.wide)) }
    }

    var resetsOnWords: String? {
        Self.date(resetsOn).map { $0.formatted(Self.style.month(.wide).day()) }
    }

    /// Read and written in UTC, so the day is the one the gateway named wherever the phone is.
    private static var style: Date.FormatStyle {
        var style = Date.FormatStyle(timeZone: TimeZone(identifier: "UTC") ?? .current)
        style.locale = Locale(identifier: "en_US")
        return style
    }

    private static func date(_ day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
