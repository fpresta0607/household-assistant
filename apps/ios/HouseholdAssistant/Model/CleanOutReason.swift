// Why the clean-out offers a photo: one of several near-duplicates of the same shot, blurry,
// or a screenshot older than a month.

import Foundation

enum CleanOutReason: String, CaseIterable, Sendable {
    case duplicate
    case blurry
    case oldScreenshot

    /// The heading the review groups these under.
    var title: String {
        switch self {
        case .duplicate:
            return "Near-duplicates"
        case .blurry:
            return "Blurry"
        case .oldScreenshot:
            return "Old screenshots"
        }
    }
}
