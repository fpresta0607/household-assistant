// Google's sign-in for Connect Google, built into the app for the household's iOS OAuth
// client, so it works the same with a gateway that describes Google and one that does not.
//
// An iOS client has no secret. PKCE is what ties the code to this phone, and the code, the
// verifier and the redirect go straight to this phone's own gateway, which exchanges them
// and keeps the lasting sign-in, so no token ever reaches the phone. It asks for what
// deploy/openclaw/plugins/household-app/google-connect.js describes: Gmail read-only,
// Calendar, and the account's verified email and its name, which the connector's page
// shows. The redirect is the client id reversed, the one Google allows an iOS client and
// the one the gateway checks, and Google answers on that scheme itself.

import Foundation

extension OAuthAuthorization {
    static let googleProvider = "google"
    static let googlePage = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let googleScopes = [
        "openid",
        "email",
        "profile",
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/calendar",
    ]
    private static let googleClientIdEnding = ".apps.googleusercontent.com"

    /// Nil unless `clientId` is a Google iOS client id by the gateway's own rule, digits, a
    /// hyphen, lowercase letters and digits, then Google's ending, so the build's
    /// placeholder is refused before Google's sheet opens.
    init?(googleClientId clientId: String, pkce: PKCE, state: String = OAuthAuthorization.freshState()) {
        guard clientId.hasSuffix(Self.googleClientIdEnding) else {
            return nil
        }
        let parts = clientId.dropLast(Self.googleClientIdEnding.count).split(separator: "-", omittingEmptySubsequences: false)
        guard
            parts.count == 2,
            !parts[0].isEmpty,
            parts[0].allSatisfy({ $0.isASCII && $0.isNumber }),
            !parts[1].isEmpty,
            parts[1].allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber) })
        else {
            return nil
        }
        let callbackScheme = "com.googleusercontent.apps.\(clientId.dropLast(Self.googleClientIdEnding.count))"
        self.init(
            provider: "Google",
            page: Self.googlePage,
            clientId: clientId,
            scopes: Self.googleScopes,
            redirectURI: "\(callbackScheme):/oauthredirect",
            callbackScheme: callbackScheme,
            pkce: pkce,
            state: state
        )
    }
}
