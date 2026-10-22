// One line of the parents' Corey & Denise group: one step of the two assistants' direct
// line, or a burst of rows one assistant logged to one topic within a second, such as a
// whole weigh-in, which reads as one line rather than one per row.

import Foundation

struct PairEntry: Equatable, Identifiable, Sendable {
    /// How long after a burst's first row another row by the same assistant to the same
    /// topic still joins it.
    static let burstMilliseconds = 1000

    /// The steps it stands for, oldest first: one, or each row of a burst.
    let events: [PairEvent]
    /// The person whose family-room question a claim or a takeover is about, when this phone
    /// knows: a takeover names only the message, so its person comes from the claim before it.
    let askedBy: String?

    private init(events: [PairEvent], askedBy: String?) {
        self.events = events
        self.askedBy = askedBy
    }

    /// The step it shows, or a burst's first row.
    var event: PairEvent {
        events[0]
    }

    var id: String {
        event.id
    }

    /// The line's steps as the group shows them, oldest first.
    static func entries(of events: [PairEvent]) -> [PairEntry] {
        var entries: [PairEntry] = []
        var askers: [String: String] = [:]
        for event in events {
            if let last = entries.last, last.isJoined(by: event) {
                entries[entries.count - 1] = PairEntry(events: last.events + [event], askedBy: nil)
                continue
            }
            var askedBy: String?
            switch event.kind {
            case .claimed:
                askedBy = event.forWho
                if let message = event.message, let person = event.forWho {
                    askers[message] = person
                }
            case .tookOver:
                askedBy = event.message.flatMap { askers[$0] }
            default:
                break
            }
            entries.append(PairEntry(events: [event], askedBy: askedBy))
        }
        return entries
    }

    /// Whether `next` is one more row of this burst: added by the same assistant to the same
    /// topic within a second of the burst's first.
    private func isJoined(by next: PairEvent) -> Bool {
        guard event.kind == .added, next.kind == .added, let topic = event.line?.topic else {
            return false
        }
        return next.by == event.by && next.line?.topic == topic && next.at - event.at < Self.burstMilliseconds
    }
}
