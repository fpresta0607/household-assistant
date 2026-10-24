// Pairing without a setup code: Sign in with Apple at the chosen person's own gateway. A
// known Apple ID pairs at once, and a new one waits for Franco (AppleSignInWaitingView).
//
// The gateway's nonce is fetched before the button can be tapped, because Apple's
// request is built the moment it is.

import AuthenticationServices
import SwiftUI
import UIKit

struct AppleSignInPanel: View {
    let member: HouseholdMember

    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @State private var nonce: String?

    var body: some View {
        let flow = model.appleSignIn
        VStack(spacing: 12) {
            if let nonce {
                SignInWithAppleButton(.continue) { request in
                    // No name and no email: the gateway knows people by Apple's user id alone.
                    request.requestedScopes = []
                    request.nonce = AppleSignInBridge.hashed(nonce)
                } onCompletion: { result in
                    complete(result)
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 52)
                .clipShape(Capsule())
            } else if flow.phase == .signingIn {
                ProgressView()
                    .frame(height: 52)
            }
            if case let .refused(reason) = flow.phase {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Palette.text)
                    .padding(12)
                    .background(Palette.errorSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                if nonce == nil {
                    Button("Try again", systemImage: "arrow.clockwise") {
                        Task {
                            nonce = await flow.begin(member)
                        }
                    }
                    .foregroundStyle(Palette.highlight)
                }
            }
        }
        .task(id: member) {
            nonce = await flow.begin(member)
        }
    }

    private func complete(_ result: Result<ASAuthorization, Error>) {
        let flow = model.appleSignIn
        nonce = nil
        switch result {
        case let .success(authorization):
            guard let token = AppleSignInBridge.identityToken(authorization) else {
                flow.appleDidNotSignIn("Apple did not say who signed in. Try again.")
                return
            }
            Task {
                if let code = await flow.finish(identityToken: token, name: UIDevice.current.name) {
                    model.pairSignedInWithApple(code)
                }
            }
        case let .failure(error):
            let isClosed = (error as? ASAuthorizationError)?.code == .canceled
            flow.appleDidNotSignIn(isClosed ? nil : "Apple could not sign you in. Try again.")
            Task {
                nonce = await flow.begin(member)
            }
        }
    }
}
