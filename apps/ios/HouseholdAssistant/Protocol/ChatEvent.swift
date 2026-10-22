// The payload of a `chat` event: one step of a streamed reply.
//
// Mirrors `ChatEventSchema` in the gateway: `status` while the run starts up,
// `delta` for each piece of text, then exactly one of `final`, `aborted` or
// `error`. A delta appends `deltaText`, unless `replace` is true, in which
// case `deltaText` is the whole reply so far.
//
// Each event also carries `message`, the reply so far as the gateway keeps it, which is
// not read: the words come from `deltaText`, and reading the whole reply again with
// every piece of it would cost the reply's length on each one.

import Foundation

struct ChatEvent: Decodable, Equatable, Sendable {
    enum State: String, Sendable {
        case status, delta, final, aborted, error
        /// A state a later gateway adds. Ignored rather than failing the frame.
        case unknown
    }

    let runId: String
    let sessionKey: String
    let seq: Int
    let state: State
    let deltaText: String?
    let replace: Bool?
    let errorMessage: String?

    private enum CodingKeys: String, CodingKey {
        case runId, sessionKey, seq, state, deltaText, replace, errorMessage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runId = try container.decode(String.self, forKey: .runId)
        sessionKey = try container.decode(String.self, forKey: .sessionKey)
        seq = try container.decode(Int.self, forKey: .seq)
        state = State(rawValue: try container.decode(String.self, forKey: .state)) ?? .unknown
        deltaText = try container.decodeIfPresent(String.self, forKey: .deltaText)
        replace = try container.decodeIfPresent(Bool.self, forKey: .replace)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
    }
}
