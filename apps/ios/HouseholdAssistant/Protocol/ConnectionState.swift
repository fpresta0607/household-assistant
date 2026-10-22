// Where the connection to the gateway stands. Every case is drawn by the UI.

import Foundation

enum ConnectionState: Equatable, Sendable {
    /// No gateway host has been entered yet, or the connection was stopped.
    case disconnected
    /// The socket is opening or the handshake is in flight.
    case connecting
    case connected
    /// The gateway knows this phone and is waiting for the operator to approve it.
    case pairingPending(requestId: String?)
    /// There is no usable credential; the shared token has to be entered again.
    case needsPairing(message: String)
    /// The link dropped and another attempt is scheduled.
    case reconnecting(attempt: Int)
    /// Retrying cannot help; the message says what a person has to do.
    case failed(message: String)

    /// The link is on its way up, so a caller with something to send may wait
    /// for it rather than fail at once.
    var isComingUp: Bool {
        switch self {
        case .connecting, .reconnecting:
            return true
        case .disconnected, .connected, .pairingPending, .needsPairing, .failed:
            return false
        }
    }
}
