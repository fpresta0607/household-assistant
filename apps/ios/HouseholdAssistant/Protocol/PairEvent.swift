// One step either assistant took on the two assistants' direct line, as
// `household-app.line` pages them (notes.js timeline): a row of the household note logged,
// corrected, done or removed, a handoff one handed the other, seen and answered, and a
// family-room question both were asked that one took, or took over from the other.
//
// A kind a later gateway adds still decodes, and shows as a plain line, and so does a step
// whose line does not read.

import Foundation

struct PairEvent: Decodable, Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        case added, corrected, done, removed, handed, seen, replied, claimed, tookOver
        /// A kind a later gateway adds, as it spells it.
        case other(String)

        init(_ name: String) {
            switch name {
            case "added": self = .added
            case "corrected": self = .corrected
            case "done": self = .done
            case "removed": self = .removed
            case "handed": self = .handed
            case "seen": self = .seen
            case "replied": self = .replied
            case "claimed": self = .claimed
            case "tookOver": self = .tookOver
            default: self = .other(name)
            }
        }
    }

    /// The note's line as the step left it.
    struct Line: Decodable, Equatable, Sendable {
        let id: String
        let topic: String
        let text: String
        /// What the row is about, such as one seedling of a weigh-in.
        let item: String?
        /// The day it happened, `YYYY-MM-DD`.
        let day: String?
        /// When it is due, `YYYY-MM-DD`.
        let due: String?
        /// Who will do it: a person, or the assistant a handoff is for.
        let owner: String?
    }

    let id: String
    /// Milliseconds since the epoch, on the clock of the gateway that took it.
    let at: Int
    /// The assistant who took it.
    let by: String
    let kind: Kind
    /// The person it was for: whoever asked for the row, or whose question was claimed.
    let forWho: String?
    /// Nil for a claim and a takeover, which change no line.
    let line: Line?
    /// The answer a `replied` step gave the handoff.
    let reply: String?
    /// The family-room message a claim or a takeover is about.
    let message: String?

    private enum CodingKeys: String, CodingKey {
        case id, at, by, kind, line, reply, message
        case forWho = "for"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        at = try container.decode(Int.self, forKey: .at)
        by = try container.decode(String.self, forKey: .by)
        kind = Kind(try container.decode(String.self, forKey: .kind))
        forWho = try? container.decodeIfPresent(String.self, forKey: .forWho)
        line = try? container.decodeIfPresent(Line.self, forKey: .line)
        reply = try? container.decodeIfPresent(String.self, forKey: .reply)
        message = try? container.decodeIfPresent(String.self, forKey: .message)
    }

    var takenAt: Date {
        Date(timeIntervalSince1970: Double(at) / 1000)
    }
}
