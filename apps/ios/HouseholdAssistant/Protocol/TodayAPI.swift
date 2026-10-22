// The household-app plugin's `today` method, typed. It needs `operator.read`, which the
// phone's pairing always has.

import Foundation

extension GatewayConnection {
    /// The assistant's newest Today card as the plugin sent it, null when it has none, kept
    /// in the gateway's own JSON so the phone can keep it as it came (RoomArchive).
    func today() async throws -> JSONValue {
        try await request("household-app.today")["today"] ?? .null
    }
}
