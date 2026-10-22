// How this app names itself in the handshake.
//
// `id` and `mode` come from the gateway's closed registries
// (`packages/gateway-protocol/src/client-info.ts`); an unknown id is refused.
// `platform` and `deviceFamily` are also bound into the v3 device signature.

import Foundation

struct ClientInfo: Equatable, Sendable {
    let id: String
    let mode: String
    let platform: String
    let deviceFamily: String
    let displayName: String
    let version: String

    static func stewardPhone(displayName: String, version: String) -> ClientInfo {
        ClientInfo(
            id: "openclaw-ios",
            mode: "ui",
            platform: "ios",
            deviceFamily: "iphone",
            displayName: displayName,
            version: version
        )
    }

    /// The same phone as a setup code's connect presents it: OpenClaw approves an
    /// iOS app's mobile node without anyone tapping Approve.
    var settingUp: ClientInfo {
        ClientInfo(
            id: id,
            mode: "node",
            platform: platform,
            deviceFamily: deviceFamily,
            displayName: displayName,
            version: version
        )
    }

    var json: JSONValue {
        .object([
            "id": .string(id),
            "displayName": .string(displayName),
            "version": .string(version),
            "platform": .string(platform),
            "deviceFamily": .string(deviceFamily),
            "mode": .string(mode),
        ])
    }
}
