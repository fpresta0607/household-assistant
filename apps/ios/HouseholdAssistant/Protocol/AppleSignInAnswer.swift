// What a gateway answers a phone that signed in with Apple.

import Foundation

enum AppleSignInAnswer: Equatable, Sendable {
    /// The Apple ID is linked to the gateway's person: the same setup code /app gives.
    case setupCode(String)
    /// Nobody linked it yet, so it waits for the approver. The ticket is what this
    /// phone shows when it asks again, so only this phone collects the code.
    case waiting(requestId: String, ticket: String)
    /// Asked again, and the approver has not said yes yet.
    case stillWaiting

    private struct Payload: Decodable {
        let setupCode: String?
        let waiting: Bool?
        let requestId: String?
        let ticket: String?
    }

    init(json: Data) throws {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: json) else {
            throw AppleSignInError.unavailable
        }
        if let code = payload.setupCode {
            self = .setupCode(code)
        } else if payload.waiting == true, let requestId = payload.requestId, let ticket = payload.ticket {
            self = .waiting(requestId: requestId, ticket: ticket)
        } else if payload.waiting == true {
            self = .stillWaiting
        } else {
            throw AppleSignInError.unavailable
        }
    }
}
