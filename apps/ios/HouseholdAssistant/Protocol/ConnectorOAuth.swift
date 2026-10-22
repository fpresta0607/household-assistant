// How a connector's provider signs in through its own page, as this phone's gateway
// describes it in `oauth`, only when the connector signs in by OAuth. The gateway keeps any
// client secret and makes the exchange, so the phone only opens the page and hands back the
// code. Notion's turns on with the gateway's env alone, so the phone needs no new build for
// it (`OAuthAuthorization`).

import Foundation

struct ConnectorOAuth: Decodable, Equatable, Sendable {
    /// `google` or `notion`.
    let provider: String
    let clientId: String
    /// The provider's page, which may carry a query of its own, such as Notion's
    /// `owner=user`.
    let authorizeUrl: String
    /// Empty for a provider that takes none, as Notion's.
    let scopes: [String]
    /// Sent back with the code exactly as given: the gateway checks it.
    let redirectUri: String
    let usesPkce: Bool
}
