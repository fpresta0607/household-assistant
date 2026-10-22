// This phone's identity to the gateway: an Ed25519 key pair.
//
// `deviceId` is the lowercase hex SHA-256 of the raw 32-byte public key, as in
// the gateway's `fingerprintPublicKey`; the public key and every signature
// travel as unpadded URL-safe base64.
//
// CryptoKit is Apple-only, so this file compiles to nothing under the Linux
// toolchain that runs the rest of the Protocol tests.

#if canImport(CryptoKit)
import CryptoKit
import Foundation

struct DeviceIdentity {
    private let privateKey: Curve25519.Signing.PrivateKey

    init() {
        privateKey = Curve25519.Signing.PrivateKey()
    }

    init(seed: Data) throws {
        privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    }

    /// The 32 bytes to keep in the Keychain.
    var seed: Data {
        privateKey.rawRepresentation
    }

    var publicKey: String {
        Base64URL.encode(privateKey.publicKey.rawRepresentation)
    }

    var deviceId: String {
        SHA256.hash(data: privateKey.publicKey.rawRepresentation)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func sign(_ payload: String) throws -> String {
        Base64URL.encode(try privateKey.signature(for: Data(payload.utf8)))
    }
}
#endif
