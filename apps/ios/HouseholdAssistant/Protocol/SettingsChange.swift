// A change to this phone's own assistant, for its own gateway only.
//
// The phone signs it with the device key it pairs with, as it signs a location report, and
// the gateway takes it only from its own person's paired phones: that is what makes each
// person control only their own assistant. The text is one line per field, exactly as
// deploy/openclaw/plugins/household-app builds it. Every value is a single line: the
// fixed ones are words from the contract, and a name is checked by `AssistantName` first.

import Foundation

struct SettingsChange: Equatable, Sendable {
    static let version = "household-app/settings/v1"

    /// When this phone signed it, in milliseconds since 1970. The gateway takes only one
    /// newer than the last it accepted.
    let at: Int
    let field: SettingsField
    let value: String

    var signedText: String {
        [Self.version, String(at), field.key, value].joined(separator: "\n")
    }

    func params(signature: String) -> JSONValue {
        .object([
            "at": .number(Double(at)),
            "field": .string(field.key),
            "value": .string(value),
            "signature": .string(signature),
        ])
    }
}
