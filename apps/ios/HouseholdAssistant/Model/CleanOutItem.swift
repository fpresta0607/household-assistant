// One photo the clean-out offers, and why. A near-duplicate names the photo of its shot that
// stays, so the review can show the two side by side.

import Foundation

struct CleanOutItem: Equatable, Sendable, Identifiable {
    let id: String
    let reason: CleanOutReason
    let keptInstead: String?
}
