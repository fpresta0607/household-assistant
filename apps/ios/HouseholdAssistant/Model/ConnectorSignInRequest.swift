// A sign-in asked for from Connectors or a connector's page: which connector, and which of
// its accounts it replaces when it is Switch account. The sign-in flow takes it from there:
// the provider's page, or the sheet for an app password or a token.

import Foundation

struct ConnectorSignInRequest: Equatable, Identifiable, Sendable {
    let connector: Connector
    var replacing: LinkedAccount? = nil

    var id: String {
        connector.id
    }
}
