// Pairing by signing in with Apple, for a phone with no setup code: ask the chosen
// person's gateway for a nonce, hand Apple its hash, send Apple's token back, and either
// pair at once or wait for Franco with the ticket the gateway gave.
//
// The wait outlives the app. Its ticket is kept with the connection's secrets, so a
// phone closed while it waited picks up where it was.

import Foundation
import Observation

@MainActor
@Observable
final class AppleSignInPairing {
    enum Phase: Equatable {
        case idle
        case signingIn
        /// Asked, and waiting for Franco to say yes from his own phone.
        case waiting(HouseholdMember)
        /// In the gateway's words, or the app's when it could not be reached.
        case refused(String)
    }

    private(set) var phase: Phase

    @ObservationIgnored private let credentials: CredentialStore
    @ObservationIgnored private let gateway: (HouseholdMember) -> AppleSignInGateway
    /// The nonce Apple was given the hash of, and whose gateway issued it.
    @ObservationIgnored private var pending: (member: HouseholdMember, nonce: String)?

    init(credentials: CredentialStore, gateway: @escaping (HouseholdMember) -> AppleSignInGateway) {
        self.credentials = credentials
        self.gateway = gateway
        if let wait = credentials.appleSignInWait, let member = HouseholdMember(rawValue: wait.member) {
            phase = .waiting(member)
        } else {
            phase = .idle
        }
    }

    /// The nonce for Apple's request, from the person's own gateway. Apple is given its
    /// SHA-256. Nil when the gateway could not be asked, and `phase` says why.
    func begin(_ member: HouseholdMember) async -> String? {
        phase = .signingIn
        do {
            let nonce = try await gateway(member).nonce()
            pending = (member, nonce)
            phase = .idle
            return nonce
        } catch {
            phase = .refused(Self.describe(error))
            return nil
        }
    }

    /// Apple's identity token for the nonce `begin` gave: a setup code to pair with at
    /// once, or nil and a wait. `name` is what Franco sees in his list.
    func finish(identityToken: String, name: String) async -> PairingCode? {
        guard let asked = pending else {
            phase = .refused("Sign in with Apple again.")
            return nil
        }
        pending = nil
        phase = .signingIn
        let member = asked.member
        do {
            switch try await gateway(member).pair(identityToken: identityToken, nonce: asked.nonce, name: name) {
            case let .setupCode(code):
                return paired(code)
            case let .waiting(requestId, ticket):
                credentials.appleSignInWait = AppleSignInWait(member: member.rawValue, requestId: requestId, ticket: ticket)
                phase = .waiting(member)
                return nil
            case .stillWaiting:
                phase = .refused(Self.describe(AppleSignInError.unavailable))
                return nil
            }
        } catch {
            phase = .refused(Self.describe(error))
            return nil
        }
    }

    /// While waiting: the setup code once Franco has said yes, otherwise nil.
    func checkWaiting() async -> PairingCode? {
        guard let wait = credentials.appleSignInWait, let member = HouseholdMember(rawValue: wait.member) else {
            return nil
        }
        do {
            switch try await gateway(member).status(requestId: wait.requestId, ticket: wait.ticket) {
            case let .setupCode(code):
                return paired(code)
            case .waiting, .stillWaiting:
                return nil
            }
        } catch let error as AppleSignInError where error != .unavailable {
            // The gateway no longer knows this wait: a day passed, or another phone asked
            // with the same Apple ID since.
            credentials.appleSignInWait = nil
            phase = .refused(Self.describe(error))
            return nil
        } catch {
            return nil
        }
    }

    /// Apple's sheet was closed or failed: nothing was sent to the gateway.
    func appleDidNotSignIn(_ reason: String?) {
        pending = nil
        phase = reason.map(Phase.refused) ?? .idle
    }

    /// Stops waiting. Franco's yes after this lets nobody in through this phone.
    func giveUp() {
        pending = nil
        credentials.appleSignInWait = nil
        phase = .idle
    }

    private func paired(_ code: String) -> PairingCode? {
        credentials.appleSignInWait = nil
        guard let pairing = PairingCode(text: code) else {
            phase = .refused("The setup code from your assistant has run out. Sign in with Apple again.")
            return nil
        }
        phase = .idle
        return pairing
    }

    private static func describe(_ error: Error) -> String {
        if case let .refused(reason) = error as? AppleSignInError {
            return reason.prefix(1).uppercased() + reason.dropFirst() + "."
        }
        return "Your assistant could not be reached. Check that Tailscale is on for this iPhone."
    }
}
