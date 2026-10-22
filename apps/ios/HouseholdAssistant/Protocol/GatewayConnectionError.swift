// Failures of the link itself, as opposed to an error the gateway answered with.

import Foundation

enum GatewayConnectionError: Error, Equatable {
    case notConnected
    case timedOut
    case unexpectedFrame
}
