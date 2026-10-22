// Turns the gateway's address, as a setup code gives it, into a WebSocket URL.
//
// `host:port` is enough. `wss://` is assumed because the gateway reaches the
// phone through `tailscale serve`, which answers only HTTPS on the tailnet
// name; `ws://` is honoured when typed, for a gateway on the same network.

import Foundation

enum GatewayAddress {
    static func url(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        let text = trimmed.contains("://") ? trimmed : "wss://" + trimmed
        guard
            let components = URLComponents(string: text),
            let scheme = components.scheme?.lowercased(),
            scheme == "ws" || scheme == "wss",
            let host = components.host,
            !host.isEmpty
        else {
            return nil
        }
        return components.url
    }
}
