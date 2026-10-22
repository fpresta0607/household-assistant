// The result of `agent.identity.get`: who this gateway's assistant is.
//
// The name and emoji shown anywhere in the app come from here and nowhere else.

import Foundation

struct AgentIdentity: Codable, Equatable, Sendable {
    let agentId: String
    let name: String?
    let emoji: String?
}
