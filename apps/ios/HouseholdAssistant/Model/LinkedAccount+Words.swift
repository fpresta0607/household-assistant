// What a connector's page says about one of its accounts: a line when its sign-in no
// longer works, and what its button to sign in again is called.

import Foundation

extension LinkedAccount {
    /// Nil while it works.
    var statusWords: String? {
        switch status {
        case .ok:
            return nil
        case .expired:
            return "Its sign-in has expired"
        case .failing:
            return "Not working right now"
        }
    }

    /// Switch account signs in with another account in its place, or with this one again
    /// once its sign-in has expired.
    var switchWords: String {
        status == .expired ? "Sign in again" : "Switch account"
    }
}
