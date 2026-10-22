#if DEBUG
// The demo household's Today card, in the shape the household-app plugin answers
// `household-app.today` with: a made-up day set from the moment it is asked for, so
// the card always has something ahead, tomorrow morning for the evening, and Psalm 46:10
// with the scripture skill's link.

import Foundation

enum DemoToday {
    static let method = "household-app.today"

    static func answer(at now: Date) -> JSONValue {
        .object(["today": card(at: now)])
    }

    private static func card(at now: Date) -> JSONValue {
        let calendar = Calendar.current
        // On the next five minutes, as a calendar's times are.
        let minute = calendar.component(.minute, from: now)
        let base = calendar.date(byAdding: .minute, value: 5 - minute % 5, to: now) ?? now
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let soccer = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        let dentist = base.addingTimeInterval(40 * 60)
        // "10:45" as the card says a time, as the assistant would write it.
        let leave = dentist.addingTimeInterval(-20 * 60).formatted(date: .omitted, time: .shortened)
            .replacingOccurrences(of: calendar.amSymbol, with: "")
            .replacingOccurrences(of: calendar.pmSymbol, with: "")
            .trimmingCharacters(in: .whitespaces)
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        return .object([
            "day": .string(String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)),
            "at": .number((now.timeIntervalSince1970 * 1000).rounded()),
            "items": .array([
                item(dentist, "Dentist", detail: "Leave by \(leave), the roads are light"),
                item(base.addingTimeInterval(3 * 3600), "Lunch with Rosa"),
                item(base.addingTimeInterval(5 * 3600), "Soccer pickup"),
                item(soccer, "Soccer"),
            ].sorted { ($0["start"]?.stringValue ?? "") < ($1["start"]?.stringValue ?? "") }),
            "verse": .object([
                "text": .string("Be still, and know that I am God."),
                "reference": .string("Psalm 46:10"),
                "link": .string("https://www.bible.com/bible/3034/PSA.46.10.BSB"),
            ]),
        ])
    }

    private static func item(_ start: Date, _ title: String, detail: String? = nil) -> JSONValue {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        var fields: [String: JSONValue] = ["start": .string(formatter.string(from: start)), "title": .string(title)]
        if let detail {
            fields["detail"] = .string(detail)
        }
        return .object(fields)
    }
}
#endif
