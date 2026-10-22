// What this phone tells its own gateway about where it is: a position while its person
// shares it, or that they stopped. Nothing else ever hears it.
//
// The phone signs it with the device key it pairs with, as it signs a message, so neither
// an assistant talked into it nor a client holding a write-scoped token can plant a
// position. The text is one line per field, integers only, exactly as
// deploy/openclaw/plugins/household-app/location.js builds it, so both write every number
// alike.

import Foundation

struct LocationReport: Equatable, Sendable {
    /// A position in whole units: millionths of a degree, metres rounded up, milliseconds.
    struct Position: Codable, Equatable, Sendable {
        let latitudeE6: Int
        let longitudeE6: Int
        let accuracy: Int
        /// When iOS measured it.
        let at: Int
    }

    static let version = "household-app/location/v1"

    /// When this phone signed it, in milliseconds since 1970.
    let at: Int
    /// Nil says sharing stopped, and the gateway forgets the position it held.
    let audience: LocationAudience?
    /// When sharing ends by itself. Nil when it has no end, and in a stop.
    let until: Int?
    let position: Position?

    static func stop(at: Int) -> LocationReport {
        LocationReport(at: at, audience: nil, until: nil, position: nil)
    }

    private var sharing: String {
        audience?.rawValue ?? "off"
    }

    var signedText: String {
        var fields: [String] = [Self.version, String(at), sharing, until.map(String.init) ?? ""]
        if let position {
            fields += [String(position.at), String(position.latitudeE6), String(position.longitudeE6), String(position.accuracy)]
        } else {
            fields += ["", "", "", ""]
        }
        return fields.joined(separator: "\n")
    }

    func params(signature: String) -> JSONValue {
        var params: [String: JSONValue] = [
            "at": .number(Double(at)),
            "sharing": .string(sharing),
            "until": .null,
            "position": .null,
            "signature": .string(signature),
        ]
        if let until {
            params["until"] = .number(Double(until))
        }
        if let position {
            params["position"] = .object([
                "latitudeE6": .number(Double(position.latitudeE6)),
                "longitudeE6": .number(Double(position.longitudeE6)),
                "accuracy": .number(Double(position.accuracy)),
                "at": .number(Double(position.at)),
            ])
        }
        return .object(params)
    }
}
