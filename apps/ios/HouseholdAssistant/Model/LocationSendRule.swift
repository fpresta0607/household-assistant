// When a position is worth telling the gateway, so the phone says where it is sparingly:
// iOS already wakes it only for a significant change or a visit, never as a stream, and
// this drops what would still be no news. An arrival or a departure is always news.

import Foundation

enum LocationSendRule {
    /// A move shorter than this, or than the position's own accuracy, says nothing new.
    static let meaningfulMetres: Double = 200
    /// Never two moves closer together than this.
    static let quietSeconds: TimeInterval = 60
    /// After this long even an unmoved position is worth saying again, so how old the
    /// gateway's one is stays true.
    static let staleSeconds: TimeInterval = 15 * 60
    /// The gateway takes nothing vaguer, and a position this vague places nobody.
    static let widestAccuracyMetres: Double = 100_000

    static func shouldSend(_ fix: LocationFix, after last: LocationFix?) -> Bool {
        guard fix.accuracy > 0, fix.accuracy <= widestAccuracyMetres else {
            return false
        }
        guard let last else {
            return true
        }
        guard fix.at > last.at else {
            return false
        }
        if fix.isVisit {
            return true
        }
        let elapsed = fix.at.timeIntervalSince(last.at)
        guard elapsed >= quietSeconds else {
            return false
        }
        return elapsed >= staleSeconds || fix.distance(to: last) >= max(meaningfulMetres, fix.accuracy)
    }
}
