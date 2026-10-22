// What a connector is signed in with, from this phone to its own gateway and nowhere
// else: a provider's authorization code with the redirect it came back on, and the PKCE
// verifier only for a provider that takes PKCE, as Google does and Notion does not; an
// account's address and app password; or a token made at the provider. The secret parts
// are `SecretText`, which never shows.

import Foundation

enum ConnectorCredential: Equatable, Sendable {
    case oauth(code: SecretText, codeVerifier: SecretText?, redirectUri: String)
    case password(username: String, secret: SecretText)
    case token(SecretText)

    /// Each value by its name in the call, in the order the gateway signs them.
    var values: [(name: String, value: String)] {
        switch self {
        case .oauth(let code, let codeVerifier, let redirectUri):
            guard let codeVerifier else {
                return [("code", code.revealed), ("redirectUri", redirectUri)]
            }
            return [("code", code.revealed), ("codeVerifier", codeVerifier.revealed), ("redirectUri", redirectUri)]
        case .password(let username, let secret):
            return [("username", username), ("secret", secret.revealed)]
        case .token(let token):
            return [("token", token.revealed)]
        }
    }
}
