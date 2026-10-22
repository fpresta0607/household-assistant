// The household-app plugin's `pair` method, typed. It needs `operator.read`, which the
// phone's pairing always has.

import Foundation

extension GatewayConnection {
    /// The newest steps of the two assistants' direct line, or those before `before`, a
    /// step's `at`.
    func pairPage(before: Int?, limit: Int = 100) async throws -> PairPage {
        var params: [String: JSONValue] = ["limit": .number(Double(limit))]
        if let before {
            params["before"] = .number(Double(before))
        }
        return try await request("household-app.pair", .object(params), as: PairPage.self)
    }
}
