// Why a sign-in through a provider's page stopped before anything reached the gateway, in
// one plain line that names the provider.

import Foundation

enum OAuthSignInFailure: Error, Equatable, Sendable {
    /// The build still has the placeholder for Google's iOS client id, or the gateway
    /// described a page this build cannot open.
    case notSetUp(provider: String)
    /// The provider answered with an error, by its own code: `access_denied` when the
    /// person said no.
    case declined(provider: String, code: String)
    /// The answer was for another sign-in, or carried no code.
    case notThisSignIn(provider: String)

    var sentence: String {
        switch self {
        case .notSetUp(let provider):
            return "\(provider) sign-in is not set up in this build yet."
        case .declined(let provider, "access_denied"):
            return "\(provider) sign-in was turned down, so nothing changed."
        case .declined(let provider, let code):
            return "\(provider) could not sign in (\(code)), so nothing changed."
        case .notThisSignIn(let provider):
            return "\(provider) answered a different sign-in, so it was not used."
        }
    }
}
