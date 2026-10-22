// Where a call stands, as the Phone app shows it: calling, connected with its time,
// reconnecting, on hold and ended, and the tap as it moves into each.

import XCTest
@testable import HouseholdAssistant

final class CallStateTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_792_050_000)

    private func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    /// A call whose sound iOS made active at once, connected as the link came up a second in.
    private func connected() -> CallState {
        var state = CallState()
        state.handle(.audio(isActive: true), at: at(0))
        state.handle(.link(isUp: true), at: at(1))
        return state
    }

    // MARK: - Calling and connected

    func testACallIsCallingUntilItHasBothTheSoundAndTheLink() {
        let orders: [[CallState.Input]] = [
            [.audio(isActive: true), .link(isUp: true)],
            [.link(isUp: true), .audio(isActive: true)],
        ]
        for order in orders {
            // Arrange
            var state = CallState()
            XCTAssertEqual(state.stage, .calling)

            // Act
            state.handle(order[0], at: at(0))
            let halfway = state.stage
            state.handle(order[1], at: at(2))

            // Assert
            XCTAssertEqual(halfway, .calling, "\(order)")
            XCTAssertEqual(state.stage, .connected, "\(order)")
            XCTAssertEqual(state.connectedAt, at(2), "\(order)")
        }
    }

    func testTheTimeCountsFromWhenTheCallFirstConnected() {
        var state = connected()
        state.handle(.link(isUp: false), at: at(30))
        state.handle(.link(isUp: true), at: at(40))
        XCTAssertEqual(state.connectedAt, at(1), "a link back does not start the time again")
        XCTAssertEqual(state.time(at: at(248)), "4:07")
    }

    func testTheLinkAndTheSoundAreKeptAsTheyFirstCame() {
        // Arrange
        var state = CallState()

        // Act
        state.handle(.link(isUp: false), at: at(0))
        state.handle(.link(isUp: true), at: at(2))
        state.handle(.audio(isActive: true), at: at(3))
        state.handle(.link(isUp: false), at: at(10))
        state.handle(.link(isUp: true), at: at(12))
        state.handle(.audio(isActive: false), at: at(20))
        state.handle(.audio(isActive: true), at: at(25))

        // Assert
        XCTAssertEqual(state.linkUpAt, at(2))
        XCTAssertEqual(state.soundAt, at(3))
    }

    func testOnHoldBeforeConnectingIsStillCalling() {
        var state = CallState()
        state.handle(.audio(isActive: true), at: at(0))
        state.handle(.interrupted(true), at: at(1))
        state.handle(.link(isUp: true), at: at(2))
        XCTAssertEqual(state.stage, .calling)
        XCTAssertNil(state.connectedAt)
        state.handle(.interrupted(false), at: at(3))
        XCTAssertEqual(state.stage, .connected)
        XCTAssertEqual(state.connectedAt, at(3))
    }

    // MARK: - Reconnecting

    func testALinkThatDropsIsReconnectingAndTheMicrophoneStaysOn() {
        var state = connected()
        state.handle(.link(isUp: false), at: at(30))
        XCTAssertEqual(state.stage, .reconnecting)
        XCTAssertTrue(state.canHear, "what the person says goes once the link is back")
        state.handle(.link(isUp: true), at: at(35))
        XCTAssertEqual(state.stage, .connected)
    }

    func testALinkDownBeforeTheCallConnectsIsStillCalling() {
        var state = CallState()
        state.handle(.audio(isActive: true), at: at(0))
        state.handle(.link(isUp: false), at: at(1))
        XCTAssertEqual(state.stage, .calling)
        XCTAssertTrue(state.canHear)
    }

    // MARK: - On hold

    /// CallKit holds the call for a phone call and takes its sound, then gives both back,
    /// the hold first: the call stays on hold until the sound is back.
    func testAHeldCallIsOnHoldUntilItsSoundIsBack() {
        var state = connected()
        state.handle(.held(true), at: at(10))
        XCTAssertEqual(state.stage, .onHold)
        XCTAssertFalse(state.canHear)
        state.handle(.audio(isActive: false), at: at(10))
        state.handle(.held(false), at: at(60))
        XCTAssertEqual(state.stage, .onHold, "off hold, but the sound is not back yet")
        state.handle(.audio(isActive: true), at: at(61))
        XCTAssertEqual(state.stage, .connected)
        XCTAssertTrue(state.canHear)
    }

    func testAnInterruptionIsOnHoldUntilItEnds() {
        var state = connected()
        state.handle(.interrupted(true), at: at(10))
        XCTAssertEqual(state.stage, .onHold)
        XCTAssertFalse(state.canHear)
        state.handle(.interrupted(false), at: at(15))
        XCTAssertEqual(state.stage, .connected)
    }

    func testTheSoundHandedBackEndsAnInterruptionThatNeverSaidItEnded() {
        var state = connected()
        state.handle(.interrupted(true), at: at(10))
        state.handle(.audio(isActive: false), at: at(10))
        state.handle(.audio(isActive: true), at: at(20))
        XCTAssertEqual(state.stage, .connected)
    }

    func testOnHoldComesBeforeReconnecting() {
        var state = connected()
        state.handle(.link(isUp: false), at: at(10))
        state.handle(.held(true), at: at(11))
        XCTAssertEqual(state.stage, .onHold)
        state.handle(.held(false), at: at(20))
        XCTAssertEqual(state.stage, .reconnecting)
    }

    // MARK: - Ended

    func testAnEndedCallStaysEnded() {
        var state = connected()
        state.handle(.ended, at: at(90))
        XCTAssertEqual(state.stage, .ended)
        XCTAssertEqual(state.endedAt, at(90))
        XCTAssertFalse(state.canHear)
        for input in [CallState.Input.audio(isActive: true), .link(isUp: true), .held(false), .interrupted(false), .ended] {
            state.handle(input, at: at(95))
            XCTAssertEqual(state.stage, .ended, "\(input)")
            XCTAssertEqual(state.endedAt, at(90), "\(input)")
        }
    }

    func testACallCanEndBeforeItConnects() {
        var state = CallState()
        state.handle(.ended, at: at(3))
        XCTAssertEqual(state.stage, .ended)
        XCTAssertNil(state.connectedAt)
    }

    // MARK: - Words

    func testWhatTheLineUnderTheNameSays() {
        var calling = CallState()
        XCTAssertEqual(calling.time(at: at(5)), "Calling\u{2026}")
        calling.handle(.ended, at: at(6))
        XCTAssertEqual(calling.time(at: at(7)), "Call ended")

        var state = connected()
        XCTAssertEqual(state.time(at: at(1)), "0:00")
        XCTAssertEqual(state.time(at: at(62)), "1:01")
        state.handle(.link(isUp: false), at: at(70))
        XCTAssertEqual(state.time(at: at(71)), "1:10", "the time runs on while reconnecting")
        state.handle(.held(true), at: at(80))
        XCTAssertEqual(state.time(at: at(3_730)), "1:02:09", "and on hold, past an hour")
    }

    func testWhatTheCallBarSays() {
        var state = connected()
        XCTAssertEqual(state.barWords(at: at(248)), "4:07")
        state.handle(.link(isUp: false), at: at(250))
        XCTAssertEqual(state.barWords(at: at(251)), "Reconnecting\u{2026}")
        state.handle(.held(true), at: at(252))
        XCTAssertEqual(state.barWords(at: at(253)), "On hold")
        state.handle(.ended, at: at(254))
        XCTAssertEqual(state.barWords(at: at(255)), "Call ended")
        XCTAssertEqual(CallState().barWords(at: at(0)), "Calling\u{2026}")
    }

    func testTheClockNeverRunsBackwards() {
        XCTAssertEqual(CallState.clock(from: at(10), to: at(0)), "0:00")
    }

    // MARK: - Haptics

    func testEachStageTapsAsTheCallMovesIntoIt() {
        let cases: [(from: CallState.Stage?, to: CallState.Stage, tap: CallState.Haptic?)] = [
            (nil, .calling, .calling),
            (.calling, .connected, .connected),
            (.connected, .reconnecting, .reconnecting),
            (.reconnecting, .connected, .connected),
            (.connected, .onHold, nil),
            (.onHold, .connected, .connected),
            (.onHold, .reconnecting, .reconnecting),
            (.connected, .ended, .ended),
            (.calling, .ended, .ended),
            (.reconnecting, .ended, .ended),
            (.connected, .connected, nil),
        ]
        for (from, to, tap) in cases {
            XCTAssertEqual(CallState.haptic(from: from, to: to), tap, "\(String(describing: from)) to \(to)")
        }
    }

    /// The call bar, or the call's screen shown again from it, sees a call under way for the
    /// first time: that is not news.
    func testACallFirstSeenUnderWayDoesNotTap() {
        for stage in [CallState.Stage.connected, .reconnecting, .onHold, .ended] {
            XCTAssertNil(CallState.haptic(from: nil, to: stage), "\(stage)")
        }
    }
}
