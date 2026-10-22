// What the connection needs from the device identity, and nothing more.
//
// A value of closures rather than the identity itself, so the connection and
// its tests build without CryptoKit.

import Foundation

struct DeviceSigner {
    let deviceId: String
    let publicKey: String
    let sign: (String) throws -> String
}

#if canImport(CryptoKit)
extension DeviceSigner {
    init(identity: DeviceIdentity) {
        self.init(deviceId: identity.deviceId, publicKey: identity.publicKey, sign: identity.sign)
    }
}
#endif
