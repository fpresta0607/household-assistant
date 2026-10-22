// This phone's key pair: made once on first launch, kept in the Keychain.

import Foundation

enum DeviceIdentityStore {
    static func loadOrCreate() -> DeviceIdentity {
        if let seed = Keychain.data(for: "device-seed"), let identity = try? DeviceIdentity(seed: seed) {
            return identity
        }
        let identity = DeviceIdentity()
        Keychain.set(identity.seed, for: "device-seed")
        return identity
    }
}
