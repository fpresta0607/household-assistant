// How a call gets the phone's sound: through CallKit, or in the app when iOS will not take
// it, so a first call connects on the first tap and a call tried again never waits on a
// CallKit that refuses it.

import XCTest
@testable import HouseholdAssistant

final class CallPlacementTests: XCTestCase {
    /// A call placed through CallKit, not answered yet.
    private func placed() -> CallPlacement {
        var placement = CallPlacement()
        XCTAssertEqual(placement.handle(.placed(hasCallKit: true)), .none)
        return placement
    }

    func testACallGoesThroughCallKitWhereThePhoneHasIt() {
        let placement = placed()
        XCTAssertEqual(placement.route, .callKit)
        XCTAssertTrue(placement.isThroughCallKit)
    }

    func testOnTheSimulatorTheCallTakesTheSoundItself() {
        var placement = CallPlacement()
        XCTAssertEqual(placement.handle(.placed(hasCallKit: false)), .takeTheSound)
        XCTAssertEqual(placement.route, .app("simulator"))
        XCTAssertFalse(placement.isThroughCallKit)
    }

    /// A refused start, as iOS answers an app that is not entitled to CallKit, used to leave
    /// the call calling with no sound for as long as the person waited.
    func testACallCallKitRefusesTakesTheSoundItselfAndSaysWhy() {
        // Arrange
        var placement = placed()

        // Act
        let effect = placement.handle(.refused(code: 1))

        // Assert
        XCTAssertEqual(effect, .takeTheSound)
        XCTAssertEqual(placement.route, .app("refused 1"))
        XCTAssertFalse(placement.isThroughCallKit, "mute and end no longer go through iOS")
    }

    /// A reset before the sound came used to end the call at once, the way Gia's ended 67 ms
    /// after her tap on 17 October.
    func testAResetBeforeTheSoundCameCarriesTheCallOnInTheApp() {
        var placement = placed()
        XCTAssertEqual(placement.handle(.reset), .takeTheSound)
        XCTAssertEqual(placement.route, .app("reset"))
    }

    func testAResetOnceTheCallHadItsSoundEndsIt() {
        // Arrange
        var placement = placed()
        _ = placement.handle(.soundActive)

        // Act
        let effect = placement.handle(.reset)

        // Assert
        XCTAssertEqual(effect, .end)
        XCTAssertEqual(placement.route, .callKit)
    }

    /// The microphone could not be started and the person tapped to try again: the call
    /// goes the way it went, and its record still says why.
    func testACallPlacedAgainGoesTheWayItWent() {
        // Arrange
        var throughCallKit = placed()
        var inTheApp = placed()
        _ = inTheApp.handle(.refused(code: 1))

        // Act
        let again = throughCallKit.handle(.placed(hasCallKit: true))
        let againInTheApp = inTheApp.handle(.placed(hasCallKit: true))

        // Assert
        XCTAssertEqual(again, .none, "asked of CallKit again")
        XCTAssertEqual(throughCallKit.route, .callKit)
        XCTAssertEqual(againInTheApp, .takeTheSound)
        XCTAssertEqual(inTheApp.route, .app("refused 1"))
    }

    func testAnAnswerOnceTheCallRunsInTheAppChangesNothing() {
        let answers: [CallPlacement.Input] = [.refused(code: 2), .reset, .soundActive]
        for answer in answers {
            // Arrange
            var placement = placed()
            _ = placement.handle(.refused(code: 1))

            // Act
            let effect = placement.handle(answer)

            // Assert
            XCTAssertEqual(effect, .none, "\(answer)")
            XCTAssertEqual(placement.route, .app("refused 1"), "\(answer)")
        }
    }

    func testAnAnswerBeforeTheCallIsPlacedChangesNothing() {
        let answers: [CallPlacement.Input] = [.refused(code: 1), .reset, .soundActive]
        for answer in answers {
            var placement = CallPlacement()
            XCTAssertEqual(placement.handle(answer), .none, "\(answer)")
            XCTAssertNil(placement.route, "\(answer)")
        }
    }

    func testTheSoundFromCallKitIsNotedOnlyForACallKitCall() {
        var placement = CallPlacement()
        _ = placement.handle(.placed(hasCallKit: false))
        _ = placement.handle(.soundActive)
        XCTAssertFalse(placement.hasHadSound)
    }
}
