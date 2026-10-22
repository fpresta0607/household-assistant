// Where a call's sound goes, for every combination of the person's choice with the Speaker
// button, the phone at the ear or not, and AirPods, a headset or the car connected or not,
// and the button that shows it.

import XCTest
@testable import HouseholdAssistant

final class CallRoutingTests: XCTestCase {
    private let airPods = CallAudioRoutes.Device(id: "F0:5C:77:12:34:56-tsco", name: "Franco\u{2019}s AirPods Pro", kind: .bluetooth)
    private let car = CallAudioRoutes.Device(id: "CarPlay-0001", name: "Gia\u{2019}s Highlander", kind: .car)

    func testACallStartsOnTheSpeaker() {
        let routing = CallRouting()
        XCTAssertEqual(routing.output, .speaker)
        XCTAssertTrue(routing.isButtonLit)
        XCTAssertTrue(routing.canToggle)
    }

    func testEveryCombinationSendsTheSoundWhereTheOwnerSaid() {
        let cases: [(isEarpieceChosen: Bool, isNearEar: Bool, isConnected: Bool, output: CallRouting.Output)] = [
            // Nothing connected: the speaker, but at the ear the earpiece.
            (false, false, false, .speaker),
            (false, true, false, .earpiece),
            // The earpiece chosen with the button stays, at the ear or lowered.
            (true, false, false, .earpiece),
            (true, true, false, .earpiece),
            // Whatever is connected takes the sound, whatever else holds.
            (false, false, true, .external),
            (false, true, true, .external),
            (true, false, true, .external),
            (true, true, true, .external),
        ]
        for (isEarpieceChosen, isNearEar, isConnected, output) in cases {
            // Arrange
            let routing = CallRouting(isEarpieceChosen: isEarpieceChosen, isNearEar: isNearEar, device: isConnected ? airPods : nil)

            // Assert
            XCTAssertEqual(
                routing.output,
                output,
                "earpiece chosen \(isEarpieceChosen), at the ear \(isNearEar), connected \(isConnected)"
            )
        }
    }

    func testRaisingThePhoneMovesTheSoundToTheEarpieceAndLoweringItMovesItBack() {
        var routing = CallRouting()
        routing.isNearEar = true
        XCTAssertEqual(routing.output, .earpiece)
        routing.isNearEar = false
        XCTAssertEqual(routing.output, .speaker)
    }

    func testTheEarpieceChosenWithTheButtonStaysWhenThePhoneIsLowered() {
        var routing = CallRouting()
        routing.isEarpieceChosen.toggle()
        routing.isNearEar = true
        routing.isNearEar = false
        XCTAssertEqual(routing.output, .earpiece)
        routing.isEarpieceChosen.toggle()
        XCTAssertEqual(routing.output, .speaker, "the button flips it back")
    }

    func testTheEarIsWatchedOnlyWhileNothingIsConnected() {
        XCTAssertTrue(CallRouting().isProximityWatched)
        XCTAssertTrue(CallRouting(isEarpieceChosen: true).isProximityWatched)
        XCTAssertFalse(CallRouting(device: airPods).isProximityWatched)
        XCTAssertFalse(CallRouting(device: car).isProximityWatched)
    }

    // MARK: - The button

    func testTheButtonIsSpeakerLitOnTheSpeakerAndUnlitOnTheEarpiece() {
        let onTheSpeaker = CallRouting()
        XCTAssertEqual(onTheSpeaker.buttonTitle, "Speaker")
        XCTAssertEqual(onTheSpeaker.buttonSymbol, "speaker.wave.2.fill")
        XCTAssertTrue(onTheSpeaker.isButtonLit)

        let onTheEarpiece = CallRouting(isEarpieceChosen: true)
        XCTAssertEqual(onTheEarpiece.buttonTitle, "Speaker")
        XCTAssertFalse(onTheEarpiece.isButtonLit)
        XCTAssertTrue(onTheEarpiece.canToggle)
    }

    /// At the ear on the speaker the sound is on the earpiece, but the choice is still the
    /// speaker, and the button says so.
    func testTheButtonShowsTheChoiceNotTheEar() {
        let atTheEar = CallRouting(isNearEar: true)
        XCTAssertEqual(atTheEar.output, .earpiece)
        XCTAssertTrue(atTheEar.isButtonLit)
    }

    func testWhileSomethingIsConnectedTheButtonShowsItAndDoesNotFlip() {
        let cases: [(device: CallAudioRoutes.Device, symbol: String)] = [
            (airPods, "airpods"),
            (car, "car.fill"),
        ]
        for (device, symbol) in cases {
            for isEarpieceChosen in [false, true] {
                let routing = CallRouting(isEarpieceChosen: isEarpieceChosen, device: device)
                XCTAssertEqual(routing.buttonTitle, "Audio", device.name)
                XCTAssertEqual(routing.buttonSymbol, symbol, device.name)
                XCTAssertTrue(routing.isButtonLit, device.name)
                XCTAssertFalse(routing.canToggle, device.name)
            }
        }
    }
}
