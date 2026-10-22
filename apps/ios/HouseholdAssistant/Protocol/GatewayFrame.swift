// Every frame on the socket is one of three shapes, told apart by `type`.

import Foundation

enum GatewayFrame: Sendable {
    case request(GatewayRequest)
    case response(GatewayResponse)
    case event(GatewayEvent)
}

extension GatewayFrame: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "req":
            self = .request(try GatewayRequest(from: decoder))
        case "res":
            self = .response(try GatewayResponse(from: decoder))
        case "event":
            self = .event(try GatewayEvent(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "unknown frame type \(type)"
            )
        }
    }
}
