// Whether App Lock holds Steward AI shut until Face ID or the iPhone's passcode opens it.
//
// Opening the app afresh is locked while Require Face ID is on. Back from the background
// it is locked again once it was away for the time App Lock allows, and not before. A
// glance at Control Center, or Face ID's own question, leaves the app inactive rather than
// in the background, so neither counts as time away. With Require Face ID off it never
// locks. The moments are on a clock that keeps counting while the iPhone sleeps and that
// changing the iPhone's time does not move, and they are plain values, so every rule is
// covered by a plain test.

import Foundation

struct AppLock: Equatable, Sendable {
    /// Whether the app is shut until its person proves it is them.
    private(set) var isLocked: Bool
    /// When the app went to the background, until it is back in front.
    private var leftAt: ContinuousClock.Instant?

    /// The app opening afresh, with Require Face ID on or off.
    init(isRequired: Bool) {
        isLocked = isRequired
    }

    mutating func movedToBack(at moment: ContinuousClock.Instant) {
        leftAt = moment
    }

    /// The app is in front again at `moment`. While Require Face ID is on, it locks once
    /// it was in the background for at least the time `timing` allows.
    mutating func movedToFront(at moment: ContinuousClock.Instant, isRequired: Bool, timing: AppLockTiming) {
        if isRequired, let leftAt, leftAt.duration(to: moment) >= timing.grace {
            isLocked = true
        }
        leftAt = nil
    }

    /// Face ID or the passcode proved it is them.
    mutating func unlock() {
        isLocked = false
    }
}
