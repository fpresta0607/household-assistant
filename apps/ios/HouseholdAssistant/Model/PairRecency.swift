// How long ago the two assistants' direct line last moved, as the family room's marker says
// it: "just now", then "4 min ago", and nothing once the line has been quiet for an hour,
// when the marker goes.

import Foundation

enum PairRecency {
    static let shownSeconds: TimeInterval = 3600

    /// Nil once the line has been quiet for `shownSeconds`. A step stamped a little ahead of
    /// this phone's clock was just now.
    static func words(lastAt: Int, now: Date) -> String? {
        let seconds = now.timeIntervalSince1970 - Double(lastAt) / 1000
        guard seconds < shownSeconds else {
            return nil
        }
        let minutes = Int(seconds / 60)
        return minutes < 1 ? "just now" : "\(minutes) min ago"
    }
}
