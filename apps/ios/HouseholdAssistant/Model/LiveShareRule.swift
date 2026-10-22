// When a live map is worth moving: iOS hands the phone a position every second or so while
// a map is live, and the family needs to see it move, not every step of it. A move longer
// than a few doors, or than the position's own accuracy, at most every ten seconds; and
// after two minutes standing still, the same place again, so the map says it is fresh.

import Foundation

enum LiveShareRule {
    static let meaningfulMetres: Double = 25
    static let quietSeconds: TimeInterval = 10
    static let staleSeconds: TimeInterval = 120

    static func shouldSend(_ fix: LocationFix, after last: LocationFix?) -> Bool {
        guard fix.accuracy > 0, fix.accuracy <= LocationSendRule.widestAccuracyMetres else {
            return false
        }
        guard let last else {
            return true
        }
        let elapsed = fix.at.timeIntervalSince(last.at)
        guard elapsed >= quietSeconds else {
            return false
        }
        return elapsed >= staleSeconds || fix.distance(to: last) >= max(meaningfulMetres, fix.accuracy)
    }
}
