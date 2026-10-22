// Builds the `connect` request that answers a challenge.
//
// A first pairing authenticates with a setup code's single-use token; every
// later connect authenticates with the device token the gateway issued.
// Whichever is sent is also the token bound into the device signature, as the
// gateway's own client does (`selectGatewayConnectAuth`).

import Foundation

enum ConnectRequest {
    static let protocolVersion = 4
    static let role = "operator"
    /// What a setup code's connect asks to be: OpenClaw approves a mobile node by
    /// itself and hands back the operator token beside it.
    static let setupRole = "node"

    struct Credential: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case bootstrapToken
            case deviceToken
        }

        let kind: Kind
        let value: String
    }

    struct SignedDevice: Equatable, Sendable {
        let id: String
        let publicKey: String
        let signature: String
    }

    static func make(
        id: String = UUID().uuidString,
        challenge: ConnectChallenge,
        client: ClientInfo,
        role: String = ConnectRequest.role,
        scopes: [String],
        credential: Credential,
        device: SignedDevice,
        locale: String
    ) -> GatewayRequest {
        let auth: JSONValue
        switch credential.kind {
        case .bootstrapToken:
            auth = .object(["bootstrapToken": .string(credential.value)])
        case .deviceToken:
            auth = .object(["deviceToken": .string(credential.value)])
        }
        return GatewayRequest(id: id, method: "connect", params: .object([
            "minProtocol": .number(Double(protocolVersion)),
            "maxProtocol": .number(Double(protocolVersion)),
            "client": client.json,
            "role": .string(role),
            "scopes": .array(scopes.map(JSONValue.string)),
            "caps": .array([]),
            "auth": auth,
            "locale": .string(locale),
            "userAgent": .string("steward-ios/\(client.version)"),
            "device": .object([
                "id": .string(device.id),
                "publicKey": .string(device.publicKey),
                "signature": .string(device.signature),
                "signedAt": .number(Double(challenge.ts)),
                "nonce": .string(challenge.nonce),
            ]),
        ]))
    }
}
