// A value that must never show: an app password, Google's authorization code or the PKCE
// verifier. It prints, debug-prints, dumps and reflects as hidden, so no description of
// anything that carries one can show it. Only the signed call that sends it reads it.

import Foundation

struct SecretText: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The value itself, for the signed text and the call that carries it.
    let revealed: String

    init(_ revealed: String) {
        self.revealed = revealed
    }

    var description: String {
        "hidden"
    }

    var debugDescription: String {
        "hidden"
    }

    var customMirror: Mirror {
        Mirror(self, children: [:])
    }
}
