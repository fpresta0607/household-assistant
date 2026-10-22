// One move of a live map this phone shared, or its stop, as `household-app.location.live`
// takes it. The phone signs it with its device key, one line per field and integers only,
// exactly as deploy/openclaw/plugins/household-app/map-share.js builds it, so nobody but
// this phone can move its person's map.

import Foundation

struct LiveLocationUpdate: Equatable, Sendable {
    static let version = "household-app/live/v1"

    /// The map message it moves.
    let messageId: String
    /// When this phone signed it, in milliseconds since 1970. The gateway takes only a
    /// newer one, and none once the share has ended.
    let at: Int
    /// Nil stops the share early.
    let position: LocationReport.Position?

    /// Nil for a message id that would span two lines, which no message has.
    var signedText: String? {
        guard !messageId.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) else {
            return nil
        }
        let place = position.map { [String($0.at), String($0.latitudeE6), String($0.longitudeE6), String($0.accuracy)] } ?? ["", "", "", ""]
        return ([Self.version, messageId, String(at)] + place).joined(separator: "\n")
    }

    func params(signature: String) -> JSONValue {
        .object([
            "messageId": .string(messageId),
            "at": .number(Double(at)),
            "position": position.map { position -> JSONValue in
                .object([
                    "latitudeE6": .number(Double(position.latitudeE6)),
                    "longitudeE6": .number(Double(position.longitudeE6)),
                    "accuracy": .number(Double(position.accuracy)),
                    "at": .number(Double(position.at)),
                ])
            } ?? .null,
            "signature": .string(signature),
        ])
    }
}
