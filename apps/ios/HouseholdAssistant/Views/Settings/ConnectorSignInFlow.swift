// How a connector's sign-in starts, wherever it is asked for: turning on one that waits for
// its sign-in in Connectors, Connect on its page, or Switch account. A provider with OAuth
// opens its own page in the system's sign-in sheet, never a web view in the app: Google's
// built into the app with a fresh PKCE pair, or the page the gateway describes for any
// other. Its code goes straight to this phone's own gateway. An app password or a token,
// which only a connector with no OAuth on its gateway asks for, opens its own sheet.

import AuthenticationServices
import SwiftUI

extension View {
    /// Starts the sign-in `request` asks for. A provider's page sets it back to nil as it
    /// opens, and a sheet when it closes.
    func connectorSignIn(_ request: Binding<ConnectorSignInRequest?>) -> some View {
        modifier(ConnectorSignInFlow(request: request))
    }
}

private struct ConnectorSignInFlow: ViewModifier {
    @Binding var request: ConnectorSignInRequest?

    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    func body(content: Content) -> some View {
        content
            .sheet(item: typed) { request in
                if request.connector.signInKind == .token {
                    ConnectorTokenSheet(connector: request.connector, replacing: request.replacing)
                } else {
                    ConnectorPasswordSheet(connector: request.connector, replacing: request.replacing)
                }
            }
            .onChange(of: request) { _, asked in
                guard let asked, asked.connector.signInKind == .oauth else {
                    return
                }
                request = nil
                signInThroughPage(asked)
            }
    }

    /// The request while it is for a sheet, an app password's or a token's.
    private var typed: Binding<ConnectorSignInRequest?> {
        Binding(
            get: {
                switch request?.connector.signInKind {
                case .password, .token:
                    return request
                case .oauth, nil:
                    return nil
                }
            },
            set: { request = $0 }
        )
    }

    /// The provider's page in the sheet that shares Safari's sign-ins, which the owner asked
    /// for on 15 October: an account already signed in on this iPhone is one tap on
    /// Continue, with the Keychain's passwords and passkeys offered as anywhere else.
    private func signInThroughPage(_ request: ConnectorSignInRequest) {
        let session = webAuthenticationSession
        let authorization = OAuthAuthorization(for: request.connector, googleClientId: Self.googleClientId, pkce: .fresh())
        Task {
            await model.assistantSettings.connectOAuth(request.connector, replacing: request.replacing, with: authorization) { page, callbackScheme in
                do {
                    return try await session.authenticate(using: page, callbackURLScheme: callbackScheme, preferredBrowserSession: .shared)
                } catch ASWebAuthenticationSessionError.canceledLogin {
                    throw CancellationError()
                }
            }
        }
    }

    /// Google's iOS client for this build, `GOOGLE_IOS_CLIENT_ID` in project.yml.
    private static var googleClientId: String {
        Bundle.main.object(forInfoDictionaryKey: "GoogleIOSClientID") as? String ?? ""
    }
}
