// The line under a month's recap, about what happened. On an iPhone with Apple Intelligence
// the on-device model writes it from the facts below (RecapWriter), and nothing leaves the
// phone; anywhere else, or when that model says nothing usable, this plain one stands in.

import Foundation

enum RecapLine {
    /// The longest line the recap shows, so a model that rambles is never shown.
    static let longest = 160

    /// "October 2026: 214 photos over 19 days, mostly cats, the beach and food."
    static func plain(for recap: MonthlyRecap) -> String {
        let photos = recap.photoCount == 1 ? "1 photo" : "\(recap.photoCount) photos"
        let days = recap.dayCount == 1 ? "1 day" : "\(recap.dayCount) days"
        let scenes = recap.scenes.map(words)
        guard !scenes.isEmpty else {
            return "\(recap.title): \(photos) over \(days)."
        }
        return "\(recap.title): \(photos) over \(days), mostly \(listed(scenes))."
    }

    /// What the on-device model is asked, with the month's facts and nothing else.
    static func prompt(for recap: MonthlyRecap) -> String {
        let scenes = recap.scenes.isEmpty ? "nothing in particular" : listed(recap.scenes.map(words))
        return """
        Write one warm sentence, under 20 words, for a family's photo recap of \(recap.title). \
        They took \(recap.photoCount) photos over \(recap.dayCount) days, mostly of \(scenes). \
        Say only what these facts support. No emoji, no quotation marks.
        """
    }

    /// The model's answer as the line, or nil when it is empty, too long, or more than a line.
    static func cleaned(_ answer: String) -> String? {
        let line = answer.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
        guard !line.isEmpty, line.count <= longest, !line.contains("\n") else {
            return nil
        }
        return line
    }

    /// A Vision label as words: "wood_processed" is "wood processed".
    private static func words(_ scene: String) -> String {
        scene.replacingOccurrences(of: "_", with: " ")
    }

    private static func listed(_ items: [String]) -> String {
        switch items.count {
        case 0:
            return ""
        case 1:
            return items[0]
        default:
            return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }
}
