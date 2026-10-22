// What each line of the Corey & Denise group says, in plain words with everyone by name:
// "Corey logged 3 rows in Seedlings", "Corey handed Denise: “…”", "Denise saw it",
// "Denise replied: “…”", "Corey took Franco's question". Whatever a line quotes comes last,
// so a line cut short still says what happened.

import Foundation

extension PairEntry {
    /// The line's words, with each participant's name from `names` by their id, or the id
    /// itself for anyone `names` lacks.
    func words(names: [String: String]) -> String {
        let name = { (id: String) in names[id] ?? id }
        let who = name(event.by)
        switch event.kind {
        case .seen:
            return "\(who) saw it"
        case .replied:
            return event.reply.map { "\(who) replied: \(Self.quoted($0))" } ?? "\(who) replied"
        case .claimed:
            return askedBy.map { "\(who) took \(name($0))'s question" } ?? "\(who) took a question"
        case .tookOver:
            return askedBy.map { "\(who) took over \(name($0))'s question" } ?? "\(who) took over a question"
        case .added, .corrected, .done, .removed, .handed, .other:
            break
        }
        guard let line = event.line else {
            if case .other = event.kind {
                return "\(who) did something this version cannot show"
            }
            return "\(who) changed the household note"
        }
        let topic = line.topic
        let text = Self.quoted(line.text)
        switch event.kind {
        case .added where events.count > 1:
            return "\(who) logged \(events.count) rows in \(topic)"
        case .added:
            return line.item.map { "\(who) logged \($0) in \(topic): \(text)" } ?? "\(who) logged in \(topic): \(text)"
        case .corrected:
            return line.item.map { "\(who) corrected \($0) in \(topic): \(text)" } ?? "\(who) corrected \(topic): \(text)"
        case .done:
            return line.item.map { "\(who) marked \($0) done in \(topic): \(text)" } ?? "\(who) marked done: \(text)"
        case .removed:
            return line.item.map { "\(who) removed \($0) from \(topic): \(text)" } ?? "\(who) removed from \(topic): \(text)"
        case .handed:
            return "\(who) handed \(line.owner.map(name) ?? "the other assistant"): \(text)"
        default:
            return "\(who) changed \(topic): \(text)"
        }
    }

    /// A quieter line under the words, or nil: each row of a burst, and the handoff a
    /// sighting or an answer is about.
    var detail: String? {
        switch event.kind {
        case .added where events.count > 1:
            return events.compactMap { $0.line.map(Self.row) }.joined(separator: ", ")
        case .seen, .replied:
            return event.line.map { Self.quoted($0.text) }
        default:
            return nil
        }
    }

    /// "Basil 4 cm", a row's item before its words.
    private static func row(_ line: PairEvent.Line) -> String {
        line.item.map { "\($0) \(line.text)" } ?? line.text
    }

    private static func quoted(_ words: String) -> String {
        "\u{201C}\(words)\u{201D}"
    }
}
