// What this phone signs to remove another of its person's iPhones from their gateway, or
// to ask it for a setup code for a new one, exactly as
// deploy/openclaw/plugins/household-app/phones.js builds it: one line per field, the
// device last, and an empty last line for a pairing, which names none.
//
// The gateway takes either only from its own person's paired phones, and only one newer
// than the last change it accepted, settings changes included.

import Foundation

struct PhoneAction: Equatable, Sendable {
    static let version = "household-app/phone/v1"

    enum Kind: Equatable, Sendable {
        /// Another phone, by OpenClaw's device id.
        case remove(device: String)
        case pair
    }

    /// When this phone signed it, in milliseconds since 1970.
    let at: Int
    let kind: Kind

    var signedText: String {
        switch kind {
        case .remove(let device):
            return [Self.version, String(at), "remove", device].joined(separator: "\n")
        case .pair:
            return [Self.version, String(at), "pair", ""].joined(separator: "\n")
        }
    }

    func params(signature: String) -> JSONValue {
        var params: [String: JSONValue] = ["at": .number(Double(at)), "signature": .string(signature)]
        if case .remove(let device) = kind {
            params["device"] = .string(device)
        }
        return .object(params)
    }
}
