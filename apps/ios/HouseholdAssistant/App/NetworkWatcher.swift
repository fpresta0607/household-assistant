// Says each time this iPhone has a usable network, back from none or moved from Wi-Fi to
// cellular, so a link waiting to try again tries at once rather than waiting out a delay
// that grows to half a minute (GatewayConnection.retryNow). Out of a lift or a dead spot, a
// message waiting to go goes as soon as it can.

import Foundation
import Network

@MainActor
final class NetworkWatcher {
    /// Runs on the main actor whenever the network is usable after a change.
    var onUsable: (() -> Void)?

    private let monitor = NWPathMonitor()

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else {
                return
            }
            Task { @MainActor in
                self?.onUsable?()
            }
        }
        monitor.start(queue: DispatchQueue(label: "household.network-watcher", qos: .utility))
    }
}
