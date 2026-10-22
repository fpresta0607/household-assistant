// What this phone has done with one message card: who it goes to, the words as he left
// them, and whether Messages sent it. Sent is the end of it. Cancelled in Messages, the
// card stays as it was, ready to send again.

import Foundation

struct MessageCardState: Equatable, Sendable {
    /// How the message sheet ended.
    enum Result: Sendable {
        case sent, cancelled, failed
    }

    /// The words to send, which he may edit on the card first.
    var words: String
    /// Nil until the phone has looked in Contacts.
    var recipient: MessageRecipient?
    /// The one he picked when several matched.
    var chosen: MessageContact?
    private(set) var isSent = false
    /// Why the last try did not go, in plain words.
    private(set) var failure: String?

    init(card: MessageCard) {
        words = card.text
    }

    /// Who the message sheet addresses: the one match, or the one he chose of several.
    /// Nil leaves To empty, for him to fill in Messages.
    var address: String? {
        switch recipient {
        case .one(let contact):
            return contact.address
        case .several:
            return chosen?.address
        case .nobody, .noAccess, nil:
            return nil
        }
    }

    /// Who the card says it is for: the contact once there is one, else the name the
    /// assistant gave.
    func recipientName(of card: MessageCard) -> String {
        switch recipient {
        case .one(let contact):
            return contact.name
        case .several:
            return chosen?.name ?? card.to
        case .nobody, .noAccess, nil:
            return card.to
        }
    }

    var canSend: Bool {
        !isSent && !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    mutating func finish(_ result: Result) {
        switch result {
        case .sent:
            isSent = true
            failure = nil
        case .cancelled:
            break
        case .failed:
            failure = "Messages could not send it. You can try again."
        }
    }
}
