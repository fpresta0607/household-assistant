// The place a map message carries: where its person was, how exactly, when iOS measured
// it, and for a live map when it ends. Whole units, as
// deploy/openclaw/plugins/household-app/map-share.js takes them, so the phone and both
// gateways sign and check the same numbers.

import Foundation

struct SharedLocation: Decodable, Equatable, Sendable {
    let latitudeE6: Int
    let longitudeE6: Int
    /// Metres, rounded up.
    let accuracy: Int
    /// When iOS measured it, in milliseconds since 1970.
    let at: Int
    /// When a live map stops moving, in milliseconds since 1970. Nil for a map shared once.
    let until: Int?

    init(position: LocationReport.Position, until: Int?) {
        latitudeE6 = position.latitudeE6
        longitudeE6 = position.longitudeE6
        accuracy = position.accuracy
        at = position.at
        self.until = until
    }

    var position: LocationReport.Position {
        LocationReport.Position(latitudeE6: latitudeE6, longitudeE6: longitudeE6, accuracy: accuracy, at: at)
    }

    var latitude: Double {
        Double(latitudeE6) / 1_000_000
    }

    var longitude: Double {
        Double(longitudeE6) / 1_000_000
    }

    var isLive: Bool {
        until != nil
    }

    var endsAt: Date? {
        until.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }

    var json: JSONValue {
        .object([
            "latitudeE6": .number(Double(latitudeE6)),
            "longitudeE6": .number(Double(longitudeE6)),
            "accuracy": .number(Double(accuracy)),
            "at": .number(Double(at)),
            "until": until.map { JSONValue.number(Double($0)) } ?? .null,
        ])
    }
}
