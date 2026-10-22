// How long to wait before the next connection attempt.

import Foundation

enum ReconnectPolicy {
    /// While approval is pending the wait is short and flat: the person is
    /// standing there watching the phone.
    static let approvalPollSeconds: Double = 5

    /// 1, 2, 4, 8, 16, then 30 seconds for every attempt after that.
    static func delaySeconds(forAttempt attempt: Int) -> Double {
        let exponent = min(max(attempt - 1, 0), 5)
        return min(Double(1 << exponent), 30)
    }
}
