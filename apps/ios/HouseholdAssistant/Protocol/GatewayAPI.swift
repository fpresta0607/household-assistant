// The handful of gateway methods this app calls, typed.
//
// Scopes, from the gateway's method table: everything here is `operator.read`.
// The family room's methods are in HouseholdAPI.swift.

import Foundation

extension GatewayConnection {
    func agentIdentity() async throws -> AgentIdentity {
        try await request("agent.identity.get", as: AgentIdentity.self)
    }

    /// Asks the gateway to send this connection a session's streamed replies and the
    /// steps of its runs' tools. A channel's run reaches nobody else, so without this a
    /// reply arrives only whole. The gateway forgets it when the connection drops.
    func followSession(_ key: String) async throws {
        _ = try await request("sessions.messages.subscribe", .object(["key": .string(key)]))
    }
}
