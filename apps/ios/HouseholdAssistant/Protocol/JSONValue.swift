// A JSON value of any shape.
//
// The gateway's payloads are open-ended in places (`snapshot`, `message`,
// `usage`, error `details`), so the codec keeps what it does not model instead
// of failing on it.

import Foundation

enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    subscript(key: String) -> JSONValue? {
        if case .object(let members) = self {
            return members[key]
        }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self {
            return value
        }
        return nil
    }

    var intValue: Int? {
        if case .number(let value) = self, value == value.rounded(), abs(value) < 9e15 {
            return Int(value)
        }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let values) = self {
            return values
        }
        return nil
    }

    /// Decodes this value as a modelled type, by way of its JSON encoding.
    func decoded<Model: Decodable>(as type: Model.Type) throws -> Model {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }
}

extension JSONValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            // Whole numbers go out as integers: `signedAt` and the protocol
            // versions are validated as integers by the gateway.
            if value == value.rounded(), abs(value) < 9e15 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case .string(let value):
            try container.encode(value)
        case .array(let values):
            try container.encode(values)
        case .object(let members):
            try container.encode(members)
        }
    }
}
