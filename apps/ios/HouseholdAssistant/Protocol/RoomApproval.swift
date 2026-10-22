// A step of an assistant's run that waits for this phone's person to say yes, as the
// household-app plugin shows it: a card in their own thread with what the step would do
// and the answers it may be given. OpenClaw decides what needs a yes; the card only asks.
//
// How it ended arrives later as an `approval` entry about the card, whoever answered it.
//
// A draft the assistant would send, an email, a booking request or the cart's order, is such
// a card too, with `send` saying what it is and where it goes, or for an order its items and
// total, and `detail` every word of it. Approve sends that one draft.

import Foundation

struct RoomApproval: Decodable, Equatable, Sendable {
    enum Decision: String, Sendable {
        /// Yes, for this one step.
        case approve = "allow-once"
        case deny
    }

    enum Outcome: String, Sendable {
        case approved, denied
        /// Nobody answered in time, or the run stopped while it waited.
        case expired
    }

    /// OpenClaw's id for the approval, which the answer is signed over.
    let id: String
    let title: String
    /// What the step would do, in a few lines: the event, or the command.
    let detail: String?
    /// Whether the step runs a command on the box, whose detail is the command itself.
    let isCommand: Bool
    /// The answers the card offers, of those this version can give.
    let decisions: [Decision]
    /// The draft Approve sends, when the step is a send.
    let send: Send?

    struct Send: Decodable, Equatable, Sendable {
        enum Kind: String, Decodable, Sendable {
            case email, booking, order
        }

        struct Item: Decodable, Equatable, Sendable {
            let name: String
            let quantity: Int
            /// Each, as the card shows it, such as "$3.49".
            let price: String
        }

        let kind: Kind
        /// The address an email or a booking request goes to.
        let to: String?
        let subject: String?
        /// An order's total, as the card shows it before the tap, such as "$28.97".
        let total: String?
        let items: [Item]?
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, detail, decisions, send
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        isCommand = try container.decodeIfPresent(String.self, forKey: .kind) == "exec"
        decisions = try container.decode([String].self, forKey: .decisions).compactMap(Decision.init(rawValue:))
        // A send of a kind a later gateway adds is shown as an ordinary card.
        send = try? container.decodeIfPresent(Send.self, forKey: .send)
    }
}

extension RoomApproval.Decision {
    /// How the card reads once this answer is given.
    var outcome: RoomApproval.Outcome {
        self == .approve ? .approved : .denied
    }
}
