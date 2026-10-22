// A text its owner got in Messages, handed to the assistant by a Shortcuts automation or by
// Siri (DraftReplyIntent): its words, and who sent it as Shortcuts names them. It goes to the
// owner's own thread as one message, in the owner's words, and the assistant answers it with
// a drafted reply (the steward-cards skill's message card) for the owner to send.

import Foundation

struct ReceivedText: Equatable, Sendable {
    let words: String
    /// A contact's name, or the number or address Shortcuts has when the sender is no contact.
    let sender: String?

    /// Nil when the text has no words to answer, such as one that is only a picture.
    init?(words: String, sender: String?) {
        let words = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else {
            return nil
        }
        self.words = words
        let sender = sender?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sender = sender?.isEmpty == false ? sender : nil
    }

    /// What the thread shows and the assistant reads:
    ///
    ///     A text from Mike Rossi:
    ///     “Are you all still coming Saturday?”
    ///     Draft my reply.
    var request: String {
        let from = sender.map { "A text from \($0):" } ?? "A text I got:"
        return "\(from)\n\u{201C}\(words)\u{201D}\nDraft my reply."
    }
}
