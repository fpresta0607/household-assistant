// A step of an assistant's run that waits for this phone's person to say yes, as the
// household-app plugin shows it: a card in their own thread with what the step would do
// and the answers it may be given. OpenClaw decides what needs a yes; the card only asks.
//
// How it ended arrives later as an `approval` entry about the card, whoever answered it.

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

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, detail, decisions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        isCommand = try container.decodeIfPresent(String.self, forKey: .kind) == "exec"
        decisions = try container.decode([String].self, forKey: .decisions).compactMap(Decision.init(rawValue:))
    }
}

extension RoomApproval.Decision {
    /// How the card reads once this answer is given.
    var outcome: RoomApproval.Outcome {
        self == .approve ? .approved : .denied
    }
}
