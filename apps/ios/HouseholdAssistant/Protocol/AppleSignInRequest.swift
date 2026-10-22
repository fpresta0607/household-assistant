// A phone that signed in with Apple and waits for the approver, as his list shows it:
// the name the phone gave, when it asked, and whose gateway it asked. Never who Apple
// says it is.

import Foundation

struct AppleSignInRequest: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    /// Milliseconds since 1970.
    let at: Int
    /// The person whose gateway it asked, and whom it joins as once approved.
    let person: String
}
