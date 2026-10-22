// The phones that signed in with Apple and wait for Franco to let them in, on either
// gateway, and his yes.
//
// Only the approver's phone sees anyone here: the gateway answers everybody else with an
// empty list. His yes is the approval text signed with this phone's own key, because
// the other gateway hears it only over the relay and believes it only from his phone.

import Foundation
import Observation

@MainActor
@Observable
final class SignInApprovals {
    private(set) var waiting: [AppleSignInRequest] = []
    /// Why the last yes did not go through, in the gateway's words.
    private(set) var refusal: String?

    @ObservationIgnored private let connection: GatewayConnection
    @ObservationIgnored private let sign: (String) throws -> String
    @ObservationIgnored private let now: () -> Date

    init(connection: GatewayConnection, sign: @escaping (String) throws -> String, now: @escaping () -> Date = Date.init) {
        self.connection = connection
        self.sign = sign
        self.now = now
    }

    /// Keeps the last list when the gateway cannot be asked, so a dropped link does not
    /// make somebody's request look gone.
    func refresh() async {
        if let list = try? await connection.appleWaiting() {
            waiting = list
        }
    }

    func approve(_ request: AppleSignInRequest) async {
        refusal = nil
        let at = Int((now().timeIntervalSince1970 * 1000).rounded())
        do {
            let signature = try sign(AppleApproval.signedText(requestId: request.id, person: request.person, at: at))
            try await connection.appleApprove(requestId: request.id, person: request.person, at: at, signature: signature)
            waiting.removeAll { $0.id == request.id }
        } catch {
            refusal = ErrorText.describe(error)
        }
    }

    /// A different gateway's list must never carry over.
    func reset() {
        waiting = []
        refusal = nil
    }
}
