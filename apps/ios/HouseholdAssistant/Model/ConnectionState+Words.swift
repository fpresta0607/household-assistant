// What Settings and Account say under this phone's person about its link to the gateway:
// whom it is paired with and how the link stands, in a few words. A link that is up has no
// word of its own, since the green dot that leads the line says it. And what a title says
// in place of its own while the link comes back, quietly, as Telegram's titles do.

import Foundation

extension ConnectionState {
    /// "Paired with Corey" while the link is up, "Paired with Corey · reconnecting" while it
    /// comes back, or what a person has to do.
    func line(pairedWith assistant: String?) -> String {
        let paired = assistant.map { "Paired with \($0)" } ?? "Not paired"
        switch self {
        case .connected: return paired
        case .connecting: return "\(paired) \u{00B7} connecting"
        case .reconnecting: return "\(paired) \u{00B7} reconnecting"
        case .pairingPending: return "Waiting for approval on the server"
        case .needsPairing(let message), .failed(let message): return message
        case .disconnected: return "Pair this phone to get started"
        }
    }

    /// "Connecting…" in place of a title while the link comes back, and nil while it is up
    /// or when a person has to act, which the banner says instead.
    var comingBackTitle: String? {
        switch self {
        case .connecting, .reconnecting: "Connecting…"
        case .disconnected: "Not connected"
        case .connected, .pairingPending, .needsPairing, .failed: nil
        }
    }
}
