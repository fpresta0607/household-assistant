// One sign-in through a provider's own page, for a connector that signs in by OAuth: the
// page the sign-in sheet opens, the scheme the answer comes back on, and the code in that
// answer. Google's is built into the app (`OAuthAuthorization+Google`). Any other is read
// from the `oauth` its gateway describes and nothing else, so a provider the gateway turns
// on, as Notion's is by the gateway's env alone, needs no new build.
//
// The phone holds no client secret. The code goes straight to this phone's own gateway,
// which exchanges it and keeps the lasting sign-in, so no token ever reaches the phone.
// With PKCE, only for a provider that takes it, the verifier goes with the code and the
// page sees only the challenge. `state` ties the answer to this sign-in, so an answer to
// any other is never sent.

import Foundation

struct OAuthAuthorization: Sendable {
    /// What a provider's https redirect page hands the answer back to the app on, as
    /// steward://connector/notion?code=...&state=...
    static let appScheme = "steward"

    /// The provider by the name a person knows it by, for what the app says about it.
    let provider: String
    let page: URL
    let clientId: String
    let scopes: [String]
    let redirectURI: String
    /// The scheme the answer comes back on, which the sign-in sheet listens for.
    let callbackScheme: String
    /// Nil for a provider that takes none.
    let pkce: PKCE?
    let state: String

    /// Sixteen fresh random bytes, for one sign-in.
    static func freshState() -> String {
        Base64URL.encode(Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }))
    }

    /// The provider's page with this sign-in's values after its own query, such as Notion's
    /// `owner=user`, which keeps none of the names set here. It carries the challenge and
    /// never the verifier.
    var url: URL {
        var sent = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
        ]
        if !scopes.isEmpty {
            sent.append(URLQueryItem(name: "scope", value: scopes.joined(separator: " ")))
        }
        if let pkce {
            sent.append(URLQueryItem(name: "code_challenge", value: pkce.challenge))
            sent.append(URLQueryItem(name: "code_challenge_method", value: "S256"))
        }
        sent.append(URLQueryItem(name: "state", value: state))
        let names = Set(sent.map(\.name))
        var components = URLComponents(url: page, resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? []).filter { !names.contains($0.name) } + sent
        return components.url!
    }

    /// The authorization code in the provider's answer to this sign-in.
    func code(from answer: URL) throws -> SecretText {
        let items = URLComponents(url: answer, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        guard value("state") == state else {
            throw OAuthSignInFailure.notThisSignIn(provider: provider)
        }
        if let error = value("error") {
            throw OAuthSignInFailure.declined(provider: provider, code: error)
        }
        guard let code = value("code"), !code.isEmpty else {
            throw OAuthSignInFailure.notThisSignIn(provider: provider)
        }
        return SecretText(code)
    }

    /// What goes to the gateway once the provider has answered with `code`: the verifier
    /// only when the page was given its challenge, and the redirect exactly as it was sent.
    func credential(code: SecretText) -> ConnectorCredential {
        .oauth(code: code, codeVerifier: pkce?.verifier, redirectUri: redirectURI)
    }
}

extension OAuthAuthorization {
    /// How `connector` signs in through a page: Google's own flow for Google, which an older
    /// gateway does not describe since it was its only OAuth, and otherwise the page its
    /// gateway describes. Nil when this build cannot open either.
    init?(for connector: Connector, googleClientId: String, pkce: PKCE, state: String = OAuthAuthorization.freshState()) {
        if let oauth = connector.oauth, oauth.provider != Self.googleProvider {
            self.init(described: oauth, provider: connector.name, pkce: pkce, state: state)
        } else {
            self.init(googleClientId: googleClientId, pkce: pkce, state: state)
        }
    }

    /// The page `oauth` describes, its answer always on the app's own scheme: a provider
    /// that allows only an https redirect, as Notion does, comes back to a page that hands
    /// the code and state on to steward://. `pkce` is used only when the provider takes it.
    /// Nil unless the page is https and the gateway named a client.
    init?(described oauth: ConnectorOAuth, provider: String, pkce: PKCE, state: String = OAuthAuthorization.freshState()) {
        guard let page = URL(string: oauth.authorizeUrl), page.scheme == "https", !oauth.clientId.isEmpty, !oauth.redirectUri.isEmpty else {
            return nil
        }
        self.init(
            provider: provider,
            page: page,
            clientId: oauth.clientId,
            scopes: oauth.scopes,
            redirectURI: oauth.redirectUri,
            callbackScheme: Self.appScheme,
            pkce: oauth.usesPkce ? pkce : nil,
            state: state
        )
    }
}
