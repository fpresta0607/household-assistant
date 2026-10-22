// The three routes a phone calls before it is paired, from
// deploy/openclaw/plugins/household-app/apple-signin.js: a nonce, Apple's identity token
// in exchange for a setup code or a wait, and asking again while it waits.
//
// They are plain HTTPS on the gateway's tailnet address with no token, since the phone
// has none yet: Apple's token is the proof. `post` is the one call out, so the tests
// answer it themselves.

import Foundation

struct AppleSignInGateway: Sendable {
    typealias Post = @Sendable (URL, Data) async throws -> (status: Int, body: Data)

    /// The gateway's HTTPS address, such as `https://household.example.ts.net:18789`.
    let base: URL
    let post: Post

    private struct Nonce: Decodable {
        let nonce: String
    }

    private struct Refusal: Decodable {
        let error: String
    }

    /// Single use, for ten minutes. Apple is given its SHA-256 and the gateway the nonce.
    func nonce() async throws -> String {
        guard let answer = try? JSONDecoder().decode(Nonce.self, from: try await call("nonce", [:])) else {
            throw AppleSignInError.unavailable
        }
        return answer.nonce
    }

    /// `name` is what Franco sees in his list of phones waiting to join.
    func pair(identityToken: String, nonce: String, name: String) async throws -> AppleSignInAnswer {
        try AppleSignInAnswer(json: try await call("pair", ["identityToken": identityToken, "nonce": nonce, "name": name]))
    }

    func status(requestId: String, ticket: String) async throws -> AppleSignInAnswer {
        try AppleSignInAnswer(json: try await call("status", ["requestId": requestId, "ticket": ticket]))
    }

    private func call(_ route: String, _ fields: [String: String]) async throws -> Data {
        let url = base.appendingPathComponent("household-app/apple/\(route)")
        let body = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        let (status, answer): (Int, Data)
        do {
            (status, answer) = try await post(url, body)
        } catch {
            throw AppleSignInError.unavailable
        }
        switch status {
        case 200:
            return answer
        case 400, 429:
            guard let refusal = try? JSONDecoder().decode(Refusal.self, from: answer) else {
                throw AppleSignInError.unavailable
            }
            throw AppleSignInError.refused(refusal.error)
        default:
            throw AppleSignInError.unavailable
        }
    }
}
