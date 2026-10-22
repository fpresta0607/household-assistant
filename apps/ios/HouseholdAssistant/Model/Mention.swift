// Typing @ in the composer offers everyone in the room by name, and picking one writes
// "@" and the name in. The gateway wakes an assistant a family message mentions, and a
// mention is the @ and the name in the words (Mention+Matching), so that is all it needs.

import Foundation

enum Mention {
    struct Candidate: Equatable {
        let participant: RoomParticipant
        /// Who they are to this phone's owner, under the name: "Your assistant",
        /// "Gia's assistant", "You". Nil for the other people.
        let role: String?
    }

    /// What follows an @ that starts the draft's last word: "" for "Can @", "co" for
    /// "Can @co". Nil when the draft does not end in one, so an address like
    /// "franco@example" or a name already finished with a space offers nobody.
    static func query(in draft: String) -> String? {
        guard let at = draft.lastIndex(of: "@") else {
            return nil
        }
        let query = draft[draft.index(after: at)...]
        guard !query.contains(where: \.isWhitespace) else {
            return nil
        }
        if at > draft.startIndex, !draft[draft.index(before: at)].isWhitespace {
            return nil
        }
        return String(query)
    }

    /// Everyone whose name starts with `query`: this phone's assistant first, then the
    /// other assistants, the other people, and this phone's owner last.
    static func candidates(matching query: String, participants: [RoomParticipant], me: RoomSelf?) -> [Candidate] {
        guard let me else {
            return []
        }
        let others = participants.filter { $0.kind == .person && $0.id != me.person }
        let ordered = participants.filter { $0.id == me.assistant }
            + participants.filter { $0.kind == .assistant && $0.id != me.assistant }
            + others
            + participants.filter { $0.id == me.person }
        return ordered
            .filter { query.isEmpty || $0.name.range(of: query, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil }
            .map { participant in
                Candidate(participant: participant, role: role(of: participant, me: me, others: others))
            }
    }

    /// The draft with what follows its last @ replaced by `name` and a space, the @ kept,
    /// since the @ is what makes the name a mention.
    static func inserting(_ name: String, into draft: String) -> String {
        guard query(in: draft) != nil, let at = draft.lastIndex(of: "@") else {
            return draft
        }
        return String(draft[...at]) + name + " "
    }

    /// The draft for asking the assistant called `name` about a message: it mentions them
    /// first, unless it already does.
    static func asking(_ name: String, in draft: String) -> String {
        isMentioned(name, in: draft) ? draft : "@\(name) " + draft
    }

    /// The other assistant is the other person's while there is one other person.
    private static func role(of participant: RoomParticipant, me: RoomSelf, others: [RoomParticipant]) -> String? {
        if participant.id == me.person {
            return "You"
        }
        if participant.id == me.assistant {
            return "Your assistant"
        }
        guard participant.kind == .assistant else {
            return nil
        }
        if others.count == 1, let owner = others.first {
            return "\(owner.name)'s assistant"
        }
        return "Assistant"
    }
}
