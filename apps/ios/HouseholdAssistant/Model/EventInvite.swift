// An event riding in a drafted text, as the calendar file Messages attaches: one event in
// iCalendar's own form (RFC 5545), which the person it goes to taps to add to their calendar.
// It carries the title, the start and end in UTC, and the place, and nothing about who sent
// it. An app cannot invite people to an event on iOS, so this file is the invitation.

import Foundation

enum EventInvite {
    /// The file's type, as Messages is asked whether it takes it.
    static let typeIdentifier = "com.apple.ical.ics"

    /// iCalendar's lines are CRLF, and none longer than 75 bytes before it is folded.
    private static let lineBytes = 75

    /// `uid` names the event for good, so a calendar given it twice keeps one; `stamp` is
    /// when the file was made.
    static func file(for event: EventCard, uid: String, stamp: Date) -> Data {
        var lines = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//Steward AI//Drafted text//EN",
            "METHOD:PUBLISH",
            "BEGIN:VEVENT",
            "UID:\(uid)",
            "DTSTAMP:\(utc(stamp))",
            "DTSTART:\(utc(event.start))",
            "DTEND:\(utc(event.calendarEnd))",
            "SUMMARY:\(escaped(event.title))",
        ]
        if let location = event.location, !location.isEmpty {
            lines.append("LOCATION:\(escaped(location))")
        }
        lines += ["END:VEVENT", "END:VCALENDAR"]
        return Data((lines.map(folded).joined(separator: "\r\n") + "\r\n").utf8)
    }

    /// "Movie night.ics": the title, kept to what any file system takes.
    static func fileName(for event: EventCard) -> String {
        var kept = ""
        kept.unicodeScalars.append(contentsOf: event.title.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "-" })
        let name = kept.trimmingCharacters(in: .whitespaces)
        return (name.isEmpty ? "Event" : String(name.prefix(60))) + ".ics"
    }

    private static func utc(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    /// TEXT as iCalendar writes it: a backslash, a semicolon, a comma and a line break each
    /// escaped.
    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// A line longer than 75 bytes goes on over lines that start with a space, never
    /// splitting a character.
    private static func folded(_ line: String) -> String {
        var parts: [String] = []
        var current = ""
        var bytes = 0
        for character in line {
            let size = String(character).utf8.count
            let limit = parts.isEmpty ? lineBytes : lineBytes - 1
            if bytes + size > limit {
                parts.append(current)
                current = ""
                bytes = 0
            }
            current.append(character)
            bytes += size
        }
        parts.append(current)
        return parts.joined(separator: "\r\n ")
    }
}
