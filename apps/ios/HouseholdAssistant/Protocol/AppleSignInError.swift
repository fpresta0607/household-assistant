// Why a sign-in with Apple did not get this phone a setup code.

import Foundation

enum AppleSignInError: Error, Equatable {
    /// The gateway turned it down and said why, in words a person can read.
    case refused(String)
    /// The gateway could not be reached, or answered with something this app does not know.
    case unavailable
}
