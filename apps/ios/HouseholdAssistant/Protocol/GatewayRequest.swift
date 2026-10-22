// A request frame: `{"type":"req","id":…,"method":…,"params":…}`.

import Foundation

struct GatewayRequest: Equatable, Sendable {
    let id: String
    let method: String
    let params: JSONValue

    init(id: String = UUID().uuidString, method: String, params: JSONValue) {
        self.id = id
        self.method = method
        self.params = params
    }
}

extension GatewayRequest: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, id, method, params
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        method = try container.decode(String.self, forKey: .method)
        params = try container.decodeIfPresent(JSONValue.self, forKey: .params) ?? .object([:])
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("req", forKey: .type)
        try container.encode(id, forKey: .id)
        try container.encode(method, forKey: .method)
        try container.encode(params, forKey: .params)
    }
}
