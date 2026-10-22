// What a reminder by place shows on this phone, and what its person may do with it.
//
// Whose it is decides: the person it watches is the one the card names, or without a
// name the person whose assistant wrote it. This phone's own assistant's reminder for this
// person is set here and goes off here. Another assistant's that would watch this person
// asks their yes, and only this phone can give it. This phone's assistant's that would
// watch the other person waits for their yes, which only their phone can give. Anybody
// else's is only shown.

import Foundation

enum PlaceReminderState: Equatable, Sendable {
    /// This person's own, not set yet.
    case readyToSet
    /// Set, and watched on this phone.
    case watching
    /// Gone off, once.
    case done
    /// Another assistant asks to watch this person.
    case askingYou(asker: String)
    case youSaidYes(asker: String)
    case youSaidNo(asker: String)
    /// This person's assistant asked to watch somebody else, who has not answered yet.
    case waitingFor(String)
    case theySaidYes(String)
    case theySaidNo(String)
    /// Somebody else's reminder, only shown.
    case theirs(String)

    /// `answers` is each person's answer to this card, by person id. `isWatching` and
    /// `hasFired` are this phone's own record of it.
    init(
        card: PlaceReminderCard,
        author: String,
        me: RoomSelf,
        participants: [RoomParticipant],
        answers: [String: PlaceAnswer],
        isWatching: Bool,
        hasFired: Bool
    ) {
        let people = participants.filter { $0.kind == .person }
        let other = people.first { $0.id != me.person }
        let watched: RoomParticipant?
        if let named = card.for?.lowercased() {
            watched = people.first { $0.id.lowercased() == named || $0.name.lowercased() == named }
        } else {
            watched = author == me.assistant ? people.first { $0.id == me.person } : other
        }
        let asker = participants.first { $0.id == author }?.name ?? author
        let isMyAssistants = author == me.assistant
        switch (watched?.id == me.person, isMyAssistants) {
        case (true, true):
            self = hasFired ? .done : isWatching ? .watching : .readyToSet
        case (true, false):
            switch answers[me.person] {
            case .yes?:
                self = .youSaidYes(asker: asker)
            case .no?:
                self = .youSaidNo(asker: asker)
            case nil:
                self = .askingYou(asker: asker)
            }
        case (false, true) where watched != nil:
            let name = watched?.name ?? ""
            switch answers[watched?.id ?? ""] {
            case .yes?:
                self = .theySaidYes(name)
            case .no?:
                self = .theySaidNo(name)
            case nil:
                self = .waitingFor(name)
            }
        default:
            self = .theirs(watched?.name ?? card.for ?? other?.name ?? "")
        }
    }
}
