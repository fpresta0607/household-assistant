// A response frame: `{"type":"res","id":…,"ok":…,"payload":…,"error":…}`.
//
// A request that said which model it wants has its answer read straight from the frame
// into that model as the frame is decoded; every other answer keeps its payload as JSON.

import Foundation

struct GatewayResponse: Sendable {
    /// What an answer carries.
    enum Body: Sendable {
        case json(JSONValue?)
        /// The model its request wanted.
        case model(any Sendable)
        /// A payload that did not read as the model its request wanted, with why, for the
        /// request to throw at once rather than wait out its term.
        case unreadable(any Error)
    }

    let id: String
    let ok: Bool
    let body: Body
    let error: GatewayErrorShape?

    /// The payload as JSON, nil for one read into a model.
    var payload: JSONValue? {
        if case .json(let payload) = body {
            return payload
        }
        return nil
    }
}

extension GatewayResponse: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, ok, payload, error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        ok = try container.decode(Bool.self, forKey: .ok)
        error = try container.decodeIfPresent(GatewayErrorShape.self, forKey: .error)
        let answerTypes = decoder.userInfo[GatewayAnswerTypes.userInfoKey] as? GatewayAnswerTypes
        guard ok, let wanted = answerTypes?.type(for: id) else {
            body = .json(try container.decodeIfPresent(JSONValue.self, forKey: .payload))
            return
        }
        do {
            body = .model(try Self.payload(as: wanted, in: container))
        } catch {
            body = .unreadable(error)
        }
    }

    private static func payload<Model: Decodable & Sendable>(
        as type: Model.Type,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> Model {
        try container.decode(type, forKey: .payload)
    }
}
