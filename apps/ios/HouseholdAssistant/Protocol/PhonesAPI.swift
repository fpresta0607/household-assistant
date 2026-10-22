// The household-app plugin's methods for Account's iPhones, typed: the person's paired
// phones, removing one, and a setup code for a new one. `phones` needs `operator.read`,
// `phones.remove` and `pair.code` need `operator.write`; the phone holds both.

import Foundation

extension GatewayConnection {
    func pairedPhones() async throws -> [PairedPhone] {
        guard let phones = try await request("household-app.phones")["phones"] else {
            throw GatewayConnectionError.unexpectedFrame
        }
        return try phones.decoded(as: [PairedPhone].self)
    }

    /// The gateway checks `signature` against its own person's paired phones, removes the
    /// phone through OpenClaw, and answers with the phones it has left.
    func removePhone(_ action: PhoneAction, signature: String) async throws -> [PairedPhone] {
        guard let phones = try await request("household-app.phones.remove", action.params(signature: signature))["phones"] else {
            throw GatewayConnectionError.unexpectedFrame
        }
        return try phones.decoded(as: [PairedPhone].self)
    }

    func newPhoneCode(_ action: PhoneAction, signature: String) async throws -> NewPhoneCode {
        try await request("household-app.pair.code", action.params(signature: signature), as: NewPhoneCode.self)
    }
}
