// When App Lock asks for Face ID: on a fresh open while Require Face ID is on, back from the
// background once the app was away for the time allowed, never back within it, never for a
// glance that only left the app inactive, and never with the lock off.

import XCTest
@testable import HouseholdAssistant

final class AppLockTests: XCTestCase {
    private let start = ContinuousClock.now

    private func at(_ seconds: Double) -> ContinuousClock.Instant {
        start.advanced(by: .seconds(seconds))
    }

    /// An open app that went to the background at the start and came back after `seconds`.
    private func back(after seconds: Double, timing: AppLockTiming, isRequired: Bool = true) -> AppLock {
        var lock = AppLock(isRequired: false)
        lock.movedToBack(at: at(0))
        lock.movedToFront(at: at(seconds), isRequired: isRequired, timing: timing)
        return lock
    }

    func testAFreshOpenIsLockedOnlyWhileFaceIDIsRequired() {
        XCTAssertTrue(AppLock(isRequired: true).isLocked)
        XCTAssertFalse(AppLock(isRequired: false).isLocked)
    }

    func testBackAfterTheTimeAllowedLocks() {
        let cases: [(AppLockTiming, Double)] = [
            (.immediately, 0),
            (.immediately, 0.5),
            (.afterOneMinute, 60),
            (.afterOneMinute, 61),
            (.afterFifteenMinutes, 15 * 60),
            (.afterFifteenMinutes, 2 * 60 * 60),
        ]
        for (timing, away) in cases {
            XCTAssertTrue(back(after: away, timing: timing).isLocked, "\(timing) after \(away) seconds away")
        }
    }

    func testBackWithinTheTimeAllowedStaysOpen() {
        let cases: [(AppLockTiming, Double)] = [
            (.afterOneMinute, 1),
            (.afterOneMinute, 59.9),
            (.afterFifteenMinutes, 60),
            (.afterFifteenMinutes, 15 * 60 - 1),
        ]
        for (timing, away) in cases {
            XCTAssertFalse(back(after: away, timing: timing).isLocked, "\(timing) after \(away) seconds away")
        }
    }

    func testWithTheLockOffItNeverLocks() {
        for timing in AppLockTiming.allCases {
            XCTAssertFalse(back(after: 24 * 60 * 60, timing: timing, isRequired: false).isLocked, "\(timing)")
        }
    }

    /// Control Center, a notification pulled down, or Face ID's own question leave the app
    /// inactive and never in the background, so it comes back open even set to Immediately.
    func testAGlanceThatNeverReachedTheBackgroundStaysOpen() {
        // Arrange
        var lock = AppLock(isRequired: false)

        // Act
        lock.movedToFront(at: at(300), isRequired: true, timing: .immediately)

        // Assert
        XCTAssertFalse(lock.isLocked)
    }

    func testUnlockedItStaysOpenUntilItIsAwayAgain() {
        // Arrange
        var lock = AppLock(isRequired: true)

        // Act
        lock.unlock()
        lock.movedToFront(at: at(10), isRequired: true, timing: .immediately)
        let isLockedAfterAGlance = lock.isLocked
        lock.movedToBack(at: at(20))
        lock.movedToFront(at: at(21), isRequired: true, timing: .immediately)

        // Assert
        XCTAssertFalse(isLockedAfterAGlance)
        XCTAssertTrue(lock.isLocked)
    }

    /// Each time away counts on its own: two short trips to the background never add up.
    func testEachTimeAwayCountsFromItsOwnStart() {
        // Arrange
        var lock = AppLock(isRequired: false)

        // Act
        lock.movedToBack(at: at(0))
        lock.movedToFront(at: at(40), isRequired: true, timing: .afterOneMinute)
        lock.movedToBack(at: at(50))
        lock.movedToFront(at: at(100), isRequired: true, timing: .afterOneMinute)

        // Assert
        XCTAssertFalse(lock.isLocked)
    }

    /// Require Face ID turned on in Settings asks the next time the app is back after the
    /// time allowed, without waiting for a fresh open.
    func testTurnedOnLaterItLocksOnTheNextReturn() {
        XCTAssertTrue(back(after: 120, timing: .afterOneMinute, isRequired: true).isLocked)
    }

    func testOnlyUnlockOpensALockedApp() {
        // Arrange
        var lock = AppLock(isRequired: true)

        // Act
        lock.movedToBack(at: at(0))
        lock.movedToFront(at: at(1), isRequired: true, timing: .afterFifteenMinutes)
        let isLockedBackWithinTheTime = lock.isLocked
        lock.unlock()

        // Assert
        XCTAssertTrue(isLockedBackWithinTheTime, "back within the time allowed does not open a locked app")
        XCTAssertFalse(lock.isLocked)
    }
}
