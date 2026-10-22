// When the connection banner shows: never for a link back within three seconds, once it has
// been down for three, gone the moment it is up, and never for a drop the person was not
// there to see that is mended within three seconds of coming back.

import XCTest
@testable import HouseholdAssistant

final class ConnectionNoticeTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ seconds: Double) -> Date {
        start.addingTimeInterval(seconds)
    }

    /// A notice on a link that was up and dropped at the start.
    private func dropped() -> ConnectionNotice {
        var notice = ConnectionNotice()
        notice.saw(.connected, at: at(-60))
        notice.saw(.reconnecting(attempt: 1), at: at(0))
        return notice
    }

    func testALinkBackWithinThreeSecondsNeverShows() {
        for downFor in [0.2, 1, 2.5, 2.99] {
            var notice = dropped()
            notice.look(at: at(downFor / 2))
            XCTAssertFalse(notice.isShown, "halfway through \(downFor) seconds down")
            notice.look(at: at(downFor))
            XCTAssertFalse(notice.isShown, "\(downFor) seconds down")
            notice.saw(.connected, at: at(downFor))
            XCTAssertFalse(notice.isShown, "back after \(downFor) seconds")
            XCTAssertNil(notice.dueAt, "back after \(downFor) seconds")
        }
    }

    func testALinkDownForThreeSecondsShows() {
        var notice = dropped()
        XCTAssertEqual(notice.dueAt, at(ConnectionNotice.delaySeconds))
        notice.look(at: at(2.999))
        XCTAssertFalse(notice.isShown)
        notice.look(at: at(3))
        XCTAssertTrue(notice.isShown)
        XCTAssertNil(notice.dueAt, "nothing more to look for")
    }

    func testTheBannerGoesTheMomentTheLinkIsUp() {
        var notice = dropped()
        notice.look(at: at(20))
        XCTAssertTrue(notice.isShown)
        notice.saw(.connected, at: at(21))
        XCTAssertFalse(notice.isShown)
        XCTAssertNil(notice.dueAt)
    }

    /// Each failed try moves the state on, but the link has been down since the first.
    func testAnotherTryDoesNotRestartTheWait() {
        var notice = ConnectionNotice()
        notice.saw(.connecting, at: at(0))
        notice.saw(.reconnecting(attempt: 1), at: at(1))
        notice.saw(.reconnecting(attempt: 2), at: at(2.5))
        XCTAssertEqual(notice.dueAt, at(3))
        notice.look(at: at(3))
        XCTAssertTrue(notice.isShown)
        notice.saw(.reconnecting(attempt: 3), at: at(6))
        XCTAssertTrue(notice.isShown, "still down, still said")
    }

    /// At launch the link is not up yet before its first try: no flash of Not connected.
    func testNoLinkYetAtLaunchWaitsLikeALinkComingUp() {
        // Arrange
        var notice = ConnectionNotice()

        // Act
        notice.saw(.disconnected, at: at(0))
        notice.saw(.connecting, at: at(0.2))
        notice.look(at: at(2))
        let isShownBeforeConnecting = notice.isShown
        notice.saw(.connected, at: at(2.5))

        // Assert
        XCTAssertFalse(isShownBeforeConnecting)
        XCTAssertFalse(notice.isShown)
        XCTAssertNil(notice.dueAt)
    }

    func testNoLinkForThreeSecondsShows() {
        // Arrange
        var notice = ConnectionNotice()

        // Act
        notice.saw(.disconnected, at: at(0))
        notice.look(at: at(3))

        // Assert
        XCTAssertTrue(notice.isShown)
    }

    func testWhatNeedsAPersonShowsAtOnce() {
        let states: [ConnectionState] = [
            .pairingPending(requestId: "req-1"),
            .needsPairing(message: "Pair this phone to get started."),
            .failed(message: "The gateway refused this token."),
        ]
        for state in states {
            var notice = dropped()
            notice.saw(state, at: at(0.5))
            XCTAssertTrue(notice.isShown, "\(state)")
            XCTAssertNil(notice.dueAt, "\(state)")
        }
    }

    func testADropInTheBackgroundMendedSoonAfterComingBackIsNeverShown() {
        var notice = ConnectionNotice()
        notice.saw(.connected, at: at(0))
        notice.moved(toFront: false, at: at(10))
        notice.saw(.reconnecting(attempt: 1), at: at(20))
        // The app may still be running in the background, and look when the time is up.
        notice.look(at: at(23))
        notice.moved(toFront: true, at: at(300))
        XCTAssertFalse(notice.isShown, "back in front")
        XCTAssertEqual(notice.dueAt, at(303))
        notice.look(at: at(302))
        XCTAssertFalse(notice.isShown)
        notice.saw(.connected, at: at(302.5))
        XCTAssertFalse(notice.isShown)
    }

    func testADropStillDownThreeSecondsAfterComingBackShows() {
        var notice = ConnectionNotice()
        notice.saw(.connected, at: at(0))
        notice.moved(toFront: false, at: at(10))
        notice.saw(.reconnecting(attempt: 1), at: at(20))
        notice.moved(toFront: true, at: at(300))
        notice.look(at: at(303))
        XCTAssertTrue(notice.isShown)
    }

    func testAnAppThatNeverLeftTheFrontKeepsItsBanner() {
        var notice = dropped()
        notice.look(at: at(5))
        notice.moved(toFront: true, at: at(6))
        XCTAssertTrue(notice.isShown)
    }

    func testComingBackWithTheLinkUpShowsNothing() {
        var notice = ConnectionNotice()
        notice.saw(.connected, at: at(0))
        notice.moved(toFront: false, at: at(10))
        notice.moved(toFront: true, at: at(300))
        XCTAssertFalse(notice.isShown)
        XCTAssertNil(notice.dueAt)
    }

    /// The screenshots draw each state as it looks once the banner says so.
    func testWithNoDelayALinkComingUpShowsAtOnce() {
        var notice = ConnectionNotice(delaySeconds: 0)
        notice.saw(.connecting, at: at(0))
        XCTAssertTrue(notice.isShown)
        XCTAssertNil(notice.dueAt)
    }
}
