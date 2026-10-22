// An event frame: `{"type":"event","event":…,"payload":…,"seq":…}`.
//
// The events that arrive many times a second are read straight from the frame into their
// models as it is decoded: a streamed reply's `chat`, and the family room's `changed` and
// `typing`. Every other event keeps its payload as JSON for whoever reads it, and so does
// one of those three that does not read as its model.

import Foundation

struct GatewayEvent: Equatable, Sendable {
    enum Body: Equatable, Sendable {
        case chat(ChatEvent)
        case room(RoomEvent)
        case json(JSONValue?)
    }

    static let chatName = "chat"

    let event: String
    let body: Body
    let seq: Int?

    /// The payload as JSON, nil for an event read into its model.
    var payload: JSONValue? {
        if case .json(let payload) = body {
            return payload
        }
        return nil
    }
}

extension GatewayEvent: Decodable {
    private enum CodingKeys: String, CodingKey {
        case event, payload, seq
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let event = try container.decode(String.self, forKey: .event)
        self.event = event
        seq = try container.decodeIfPresent(Int.self, forKey: .seq)
        if let model = Self.model(of: event, in: container) {
            body = model
        } else {
            body = .json(try container.decodeIfPresent(JSONValue.self, forKey: .payload))
        }
    }

    /// The payload of one of the events read into a model, or nil to keep it as JSON.
    private static func model(of event: String, in container: KeyedDecodingContainer<CodingKeys>) -> Body? {
        switch event {
        case chatName:
            return (try? container.decode(ChatEvent.self, forKey: .payload)).map(Body.chat)
        case RoomEvent.changedName, RoomEvent.typingName:
            return (try? container.superDecoder(forKey: .payload)).flatMap { RoomEvent(event, payload: $0) }.map(Body.room)
        default:
            return nil
        }
    }
}
