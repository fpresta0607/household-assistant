// When App Lock asks for Face ID again once Steward AI has been in the background: at
// once, after a minute away, or after fifteen. Opening the app afresh always asks.

import Foundation

enum AppLockTiming: String, CaseIterable, Sendable {
    case immediately, afterOneMinute, afterFifteenMinutes

    var label: String {
        switch self {
        case .immediately:
            return "Immediately"
        case .afterOneMinute:
            return "After 1 minute"
        case .afterFifteenMinutes:
            return "After 15 minutes"
        }
    }

    /// How long the app may be away before it asks again.
    var grace: Duration {
        switch self {
        case .immediately:
            return .zero
        case .afterOneMinute:
            return .seconds(60)
        case .afterFifteenMinutes:
            return .seconds(15 * 60)
        }
    }
}
