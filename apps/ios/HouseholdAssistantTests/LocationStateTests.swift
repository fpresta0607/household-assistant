// Whether this iPhone shares where it is, read the same way by every screen that says so:
// the Location row in Settings and in Account show the label, and Location the sentence
// under its switch. Account once said "On" for iOS's permission beside a Location whose
// switch was off.

import XCTest
@testable import HouseholdAssistant

final class LocationStateTests: XCTestCase {
    /// 5:51:59 PM in Indianapolis on 15 October 2026.
    private let clock = Date(timeIntervalSince1970: 1_792_101_119)

    private static let indianapolis: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Indiana/Indianapolis")!
        return calendar
    }()

    private func sharing(_ audience: LocationAudience, _ span: LocationSpan, isPaused: Bool = false) -> LocationSharing {
        var sharing = LocationSharing(audience: audience, span: span, from: clock, calendar: Self.indianapolis)
        sharing.isPaused = isPaused
        return sharing
    }

    func testEachStateComesFromWhatIOSAllowsTheSwitchAndWhatTheGatewayHolds() {
        let hour = sharing(.assistant, .hour)
        let paused = sharing(.family, .always, isPaused: true)
        let cases: [(String, PermissionStatus, LocationSharing?, Bool, LocationState)] = [
            ("off, as everybody starts", .notAsked, nil, false, .off(isStillHeld: false)),
            ("off with iOS allowing it, as the owner saw it", .allowed, nil, false, .off(isStillHeld: false)),
            ("off before the stop reaches the gateway", .allowed, nil, true, .off(isStillHeld: true)),
            ("sharing", .allowed, hour, true, .sharing(hour)),
            ("sharing before the first position is sent", .allowed, hour, false, .sharing(hour)),
            ("sharing before iOS has been read", .notAsked, hour, true, .sharing(hour)),
            ("paused", .allowed, paused, false, .paused(isStillHeld: false)),
            ("paused before the stop reaches the gateway", .allowed, paused, true, .paused(isStillHeld: true)),
            ("not allowed with the switch off", .denied, nil, false, .notAllowed(isStillHeld: false)),
            ("not allowed with the switch still on", .denied, hour, true, .notAllowed(isStillHeld: true)),
            ("not allowed while paused", .denied, paused, false, .notAllowed(isStillHeld: false)),
        ]

        for (label, permission, sharing, isHeld, expected) in cases {
            let state = LocationState(permission: permission, sharing: sharing, isHeldByGateway: isHeld)

            XCTAssertEqual(state, expected, label)
        }
    }

    func testEachStateSaysWhatItMeansInPlainWords() {
        let cases: [(LocationState, String, String)] = [
            (.notAllowed(isStillHeld: false), "Not allowed", "Not allowed in iOS Settings, so Corey does not know where you are."),
            (.notAllowed(isStillHeld: true), "Not allowed", "Not allowed in iOS Settings. Corey forgets where you were once this iPhone gets through."),
            (.off(isStillHeld: false), "Off", "Off. Corey does not know where you are."),
            (.off(isStillHeld: true), "Off", "Off. Corey forgets where you were once this iPhone gets through."),
            (.paused(isStillHeld: false), "Paused", "Paused. Corey has forgotten where you were."),
            (.paused(isStillHeld: true), "Paused", "Paused. Corey forgets where you were once this iPhone gets through."),
            (.sharing(sharing(.assistant, .tonight)), "Sharing", "Sharing with Corey until midnight."),
            (.sharing(sharing(.family, .tonight)), "Sharing", "Sharing with Corey and the family room until midnight."),
            (.sharing(sharing(.assistant, .always)), "Sharing", "Sharing with Corey until you stop it."),
        ]

        for (state, label, sentence) in cases {
            XCTAssertEqual(state.label, label, "\(state)")
            XCTAssertEqual(state.sentence(assistant: "Corey"), sentence, "\(state)")
        }
        let hour = sharing(.assistant, .hour)
        XCTAssertEqual(LocationState.sharing(hour).sentence(assistant: "Corey"), "Sharing with Corey \(hour.endWords).")
        XCTAssertTrue(hour.endWords.hasPrefix("until "), "an hour ends at a time of day")
    }

    /// Every combination of what iOS allows, the app's own switch and what the gateway
    /// holds, on either household's iPhone: Account's row and Location say the same thing,
    /// with the assistant's own name, and Location's switch never contradicts them.
    func testAccountAndLocationAgreeInEveryCombination() {
        let switches: [LocationSharing?] = [nil] + LocationAudience.allCases.flatMap { audience in
            LocationSpan.allCases.flatMap { span in
                [false, true].map { isPaused in sharing(audience, span, isPaused: isPaused) }
            }
        }

        for permission in [PermissionStatus.notAsked, .allowed, .denied] {
            for choice in switches {
                for isHeld in [false, true] {
                    let state = LocationState(permission: permission, sharing: choice, isHeldByGateway: isHeld)
                    let combination = "\(permission), \(String(describing: choice)), held \(isHeld)"
                    for (assistant, other) in [("Corey", "Denise"), ("Denise", "Corey")] {
                        // The label ends the Location row in Settings and in Account; the
                        // sentence is under it in Account, and under Location's switch.
                        let label = state.label
                        let sentence = state.sentence(assistant: assistant)

                        XCTAssertTrue(sentence.hasPrefix(label), "\(combination): \(sentence)")
                        XCTAssertTrue(sentence.contains(assistant), "\(combination): \(sentence)")
                        XCTAssertFalse(sentence.contains(other), "\(combination): \(sentence)")
                    }
                    // Location's switch is the app's own choice: on exactly while the words
                    // say sharing or paused, unless iOS says no, which the words then say.
                    let isSwitchOn = choice != nil
                    if permission == .denied {
                        XCTAssertEqual(state.label, "Not allowed", combination)
                    } else {
                        XCTAssertEqual(isSwitchOn, ["Sharing", "Paused"].contains(state.label), combination)
                    }
                }
            }
        }
    }
}
