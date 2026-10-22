// How a call came up, as it is sent with the call's end for the gateway's log: each moment
// counted from the tap, and the route the call took.

import XCTest
@testable import HouseholdAssistant

final class CallSetupTests: XCTestCase {
    private let tap = Date(timeIntervalSince1970: 1_792_050_000)

    private func at(_ seconds: TimeInterval) -> Date {
        tap.addingTimeInterval(seconds)
    }

    private func throughCallKit() -> CallPlacement {
        var placement = CallPlacement()
        _ = placement.handle(.placed(hasCallKit: true))
        return placement
    }

    func testEachMomentCountsFromTheTap() {
        // Arrange
        var state = CallState()
        state.handle(.link(isUp: true), at: at(0))
        state.handle(.audio(isActive: true), at: at(0.412))

        // Act
        let setup = CallSetup(build: "18", tappedAt: tap, state: state, placement: throughCallKit(), firstSentAt: at(3), firstReplyAt: at(5.31))

        // Assert
        XCTAssertEqual(setup.linkMs, 0)
        XCTAssertEqual(setup.soundMs, 412)
        XCTAssertEqual(setup.connectedMs, 412)
        XCTAssertEqual(setup.firstReplyMs, 2310)
        XCTAssertEqual(setup.route, "callkit")
        XCTAssertEqual(setup.params, .object([
            "build": .string("18"),
            "route": .string("callkit"),
            "linkMs": .number(0),
            "soundMs": .number(412),
            "connectedMs": .number(412),
            "firstReplyMs": .number(2310),
        ]))
    }

    /// Rosa's retry on 17 October: 21 seconds calling, never connected, nothing said.
    func testACallThatNeverConnectedSendsOnlyWhatItReached() {
        // Arrange
        var state = CallState()
        state.handle(.link(isUp: true), at: at(0))
        state.handle(.ended, at: at(21))
        var placement = throughCallKit()
        _ = placement.handle(.refused(code: 1))

        // Act
        let setup = CallSetup(build: "17", tappedAt: tap, state: state, placement: placement, firstSentAt: nil, firstReplyAt: nil)

        // Assert
        XCTAssertEqual(setup.params, .object([
            "build": .string("17"),
            "route": .string("app refused 1"),
            "linkMs": .number(0),
        ]))
    }

    func testALinkThatCameUpLaterCountsTheWaitAndAReplyThatNeverCameCountsNothing() {
        var state = CallState()
        state.handle(.audio(isActive: true), at: at(0.3))
        state.handle(.link(isUp: true), at: at(16.5))
        let setup = CallSetup(build: "18", tappedAt: tap, state: state, placement: throughCallKit(), firstSentAt: at(20), firstReplyAt: nil)
        XCTAssertEqual(setup.linkMs, 16_500)
        XCTAssertEqual(setup.connectedMs, 16_500)
        XCTAssertNil(setup.firstReplyMs)
    }

    func testACallEndedBeforeItWasPlacedSaysSo() {
        let setup = CallSetup(build: "18", tappedAt: tap, state: CallState(), placement: CallPlacement(), firstSentAt: nil, firstReplyAt: nil)
        XCTAssertEqual(setup.route, "unplaced")
        XCTAssertNil(setup.linkMs)
    }
}
