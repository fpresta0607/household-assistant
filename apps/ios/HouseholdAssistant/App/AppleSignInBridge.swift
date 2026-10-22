// The parts of Sign in with Apple that need Apple's frameworks: the hash of the
// gateway's nonce that Apple's request carries, the identity token out of Apple's
// answer, and the HTTPS post that AppleSignInGateway makes.

import AuthenticationServices
import CryptoKit
import Foundation

enum AppleSignInBridge {
    /// Apple puts this in the token, and the gateway checks it is the hash of its nonce.
    static func hashed(_ nonce: String) -> String {
        SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func identityToken(_ authorization: ASAuthorization) -> String? {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            return nil
        }
        return credential.identityToken.flatMap { String(data: $0, encoding: .utf8) }
    }

    static let post: AppleSignInGateway.Post = { url, body in
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}
