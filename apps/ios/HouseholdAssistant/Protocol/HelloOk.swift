// The payload of a successful `connect`.
//
// Only what the app acts on is modelled. `auth.deviceToken` appears when the
// gateway issues or rotates this device's token, and it is persisted.

import Foundation

struct HelloOk: Decodable, Equatable, Sendable {
    struct Features: Decodable, Equatable, Sendable {
        let methods: [String]
        let events: [String]
    }

    struct Auth: Decodable, Equatable, Sendable {
        let role: String
        let deviceToken: String?
        /// Only after a setup code's connect: the tokens for the other roles the
        /// phone was approved for, the operator token among them.
        let deviceTokens: [IssuedToken]?
    }

    struct IssuedToken: Decodable, Equatable, Sendable {
        let deviceToken: String
        let role: String
    }

    struct Policy: Decodable, Equatable, Sendable {
        let tickIntervalMs: Int
    }

    struct Snapshot: Decodable, Equatable, Sendable {
        let sessionDefaults: SessionDefaults
    }

    struct SessionDefaults: Decodable, Equatable, Sendable {
        /// The session the phone chats in, for example `agent:main:main`.
        let mainSessionKey: String
    }

    let protocolVersion: Int
    let features: Features
    let auth: Auth
    let policy: Policy
    let snapshot: Snapshot

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case features, auth, policy, snapshot
    }
}
