// How a call with the assistant gets the phone's sound: as a real iOS call through CallKit
// (SystemCall), or run by the app itself, as on the Simulator, where CallKit cannot run a
// call. A call iOS will not take still goes through: when CallKit refuses to start it, or
// iOS resets CallKit before the call has its sound, the call takes the sound itself and
// connects all the same, without the green pill. A call that already had its sound from
// CallKit ends on a reset, since iOS has ended it everywhere.
//
// The way the call went is kept for its record (CallSetup), so the gateway's log shows
// whose calls iOS refused, and why. Pure: what iOS answered in, what to do out.

import Foundation

struct CallPlacement: Equatable, Sendable {
    enum Route: Equatable, Sendable {
        /// Through CallKit, which has the call or has not answered yet.
        case callKit
        /// Run by the app itself, and why: "simulator", "refused" with CallKit's error code,
        /// or "reset".
        case app(String)
    }

    enum Input: Equatable, Sendable {
        /// The call was placed: through CallKit when the phone has it, in the app otherwise.
        /// Placed again after its sound could not be started, it goes the same way again.
        case placed(hasCallKit: Bool)
        /// CallKit would not start the call, with its error's code.
        case refused(code: Int)
        /// iOS reset CallKit, which ends every call it had.
        case reset
        /// iOS made the call's sound active.
        case soundActive
    }

    enum Effect: Equatable, Sendable {
        case none
        /// Take the sound for the call here, without CallKit.
        case takeTheSound
        /// End the call: iOS has ended it.
        case end
    }

    /// Nil until the call is placed.
    private(set) var route: Route?
    /// Whether CallKit has handed this call its sound.
    private(set) var hasHadSound = false

    /// Whether muting, holding and ending go through iOS.
    var isThroughCallKit: Bool {
        route == .callKit
    }

    mutating func handle(_ input: Input) -> Effect {
        switch input {
        case .placed(let hasCallKit):
            switch route {
            case nil:
                guard hasCallKit else {
                    route = .app("simulator")
                    return .takeTheSound
                }
                route = .callKit
                return .none
            case .callKit:
                return .none
            case .app:
                return .takeTheSound
            }
        case .refused(let code):
            return runInTheApp(because: "refused \(code)")
        case .reset:
            return hasHadSound ? .end : runInTheApp(because: "reset")
        case .soundActive:
            if isThroughCallKit {
                hasHadSound = true
            }
            return .none
        }
    }

    private mutating func runInTheApp(because reason: String) -> Effect {
        guard isThroughCallKit else {
            return .none
        }
        route = .app(reason)
        return .takeTheSound
    }
}
