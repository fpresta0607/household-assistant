// A sign-in with Apple waiting for the approver: whose gateway it asked, and what this
// phone shows to collect its setup code once he says yes. Kept with the connection's
// secrets, since the ticket is what lets this phone, and only this phone, in.

import Foundation

struct AppleSignInWait: Codable, Equatable, Sendable {
    /// A `HouseholdMember` raw value.
    let member: String
    let requestId: String
    let ticket: String
}
