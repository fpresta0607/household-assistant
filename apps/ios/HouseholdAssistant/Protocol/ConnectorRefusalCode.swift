// Why the gateway would not take a connector's sign-in or sign-out, by the rule its refusal
// names: INVALID_REQUEST with `details.detailCode`, as connect.js, google-connect.js and
// notion-connect.js refuse. A refusal with none, or with one this build does not know, is
// shown in the gateway's own words instead.

import Foundation

enum ConnectorRefusalCode: String, Sendable {
    case signInNotSetUp = "SIGNIN_NOT_SET_UP"
    case providerRefused = "PROVIDER_REFUSED"
    case scopesMissing = "SCOPES_MISSING"
    case noSuchAccount = "NO_SUCH_ACCOUNT"
    case accountIsOnTheBox = "ACCOUNT_IS_ON_THE_BOX"
    case signature = "SIGNATURE"
    case stale = "STALE"
    case badValue = "BAD_VALUE"

    init?(_ refusal: GatewayErrorShape) {
        guard let code = refusal.details?["detailCode"]?.stringValue else {
            return nil
        }
        self.init(rawValue: code)
    }
}
