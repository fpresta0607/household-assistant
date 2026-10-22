// Links this phone's person's Apple ID to their gateway, so a new iPhone can join as
// them by signing in with Apple, with no code and nobody to approve it. A group of its
// own on Account.
//
// The gateway's nonce is fetched before the button can be tapped, because Apple's
// request is built the moment it is.

import AuthenticationServices
import SwiftUI

struct LinkAppleIDSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @State private var nonce: String?
    @State private var refusal: String?

    var body: some View {
        SettingsGroup(
            "Sign in with Apple",
            note: "Link your Apple ID once, and a new iPhone joins as you by signing in with Apple, with no code from \(model.assistantName).",
            refusal: refusal
        ) {
            if model.settings.hasLinkedAppleID {
                SettingsRow("Sign in with Apple", subtitle: "Linked. A new iPhone can join as you.") {
                    BrandTile("apple")
                } trailing: {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(Palette.highlight)
                }
            } else if let nonce {
                SignInWithAppleButton(.signIn) { request in
                    // No name and no email: the gateway knows people by Apple's user id alone.
                    request.requestedScopes = []
                    request.nonce = AppleSignInBridge.hashed(nonce)
                } onCompletion: { result in
                    complete(result, nonce: nonce)
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 48)
                .clipShape(Capsule())
                .padding(14)
            } else {
                SettingsRow("Sign in with Apple") {
                    BrandTile("apple")
                } trailing: {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        // The gateway gives a nonce only over a live link, so it is asked again once there is one.
        .task(id: model.connection.state == .connected) {
            await fetchNonce()
        }
    }

    private func fetchNonce() async {
        guard !model.settings.hasLinkedAppleID, model.connection.state == .connected else {
            return
        }
        do {
            nonce = try await model.connection.appleNonce()
            refusal = nil
        } catch {
            refusal = ErrorText.describe(error)
        }
    }

    private func complete(_ result: Result<ASAuthorization, Error>, nonce used: String) {
        nonce = nil
        refusal = nil
        Task {
            switch result {
            case let .success(authorization):
                if let token = AppleSignInBridge.identityToken(authorization) {
                    do {
                        try await model.connection.appleLink(identityToken: token, nonce: used)
                        model.settings.hasLinkedAppleID = true
                    } catch {
                        refusal = ErrorText.describe(error)
                    }
                } else {
                    refusal = "Apple did not say who signed in. Try again."
                }
            case let .failure(error):
                if (error as? ASAuthorizationError)?.code != .canceled {
                    refusal = "Apple could not sign you in. Try again."
                }
            }
            // A nonce works once, so another try needs a fresh one.
            await fetchNonce()
        }
    }
}
