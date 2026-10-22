// A connector's sign-in or sign-out, for this phone's own gateway only.
//
// The phone signs it with its device key, as it signs a settings change, and the gateway
// takes it only from its own person's paired phones, on the replay guard it shares with
// settings changes. The text is one line per field, exactly as
// deploy/openclaw/plugins/household-app/connect.js builds it: the version, when, connect
// or disconnect, the connector's id, then each value of the sign-in in order, and last the
// account it replaces when it is Switch account. A disconnect's one value is the account
// it forgets, or none for every sign-in, as the builds before accounts were listed send
// it. No value holds a newline: the gateway refuses one.

import Foundation

struct ConnectorChange: Equatable, Sendable {
    static let version = "household-app/connect/v1"

    enum Action: Equatable, Sendable {
        /// `replacing` is the account the gateway forgets once the new one is linked.
        case connect(ConnectorCredential, replacing: String?)
        /// `account` nil forgets the connector's own sign-in.
        case disconnect(account: String?)
    }

    /// When this phone signed it, in milliseconds since 1970. The gateway takes only one
    /// newer than the last change it accepted, settings changes included.
    let at: Int
    /// The connector's id from `connectors`.
    let connector: String
    let action: Action

    var method: String {
        "household-app.connector.\(word)"
    }

    var signedText: String {
        ([Self.version, String(at), word, connector] + values.map { $0.value }).joined(separator: "\n")
    }

    func params(signature: String) -> JSONValue {
        var params: [String: JSONValue] = [
            "at": .number(Double(at)),
            "connector": .string(connector),
            "signature": .string(signature),
        ]
        for (name, value) in values {
            params[name] = .string(value)
        }
        return .object(params)
    }

    private var word: String {
        switch action {
        case .connect:
            return "connect"
        case .disconnect:
            return "disconnect"
        }
    }

    private var values: [(name: String, value: String)] {
        switch action {
        case .connect(let credential, let replacing):
            guard let replacing else {
                return credential.values
            }
            return credential.values + [(name: "replacing", value: replacing)]
        case .disconnect(let account):
            guard let account else {
                return []
            }
            return [(name: "accountId", value: account)]
        }
    }
}
