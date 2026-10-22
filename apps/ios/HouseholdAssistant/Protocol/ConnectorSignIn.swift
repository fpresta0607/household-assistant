// How a connector signs in from the phone: `oauth` through the provider's own page in a
// sign-in sheet, `password` an account's app password typed into a sheet, and `token` a
// token made at the provider and pasted into a sheet, which only a connector with no
// OAuth on its gateway asks for.

import Foundation

enum ConnectorSignIn: String, Decodable, Sendable {
    case oauth
    case password
    case token
}
