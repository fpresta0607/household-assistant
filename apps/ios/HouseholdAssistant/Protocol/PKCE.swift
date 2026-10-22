// Proof Key for Code Exchange (RFC 7636) with S256, for Connect Google: a verifier of 64
// fresh random bytes each time, and its challenge, the SHA-256 of the verifier's own
// characters. Google's page sees only the challenge. The verifier goes with the code to
// this phone's own gateway, which proves with it that the code is this phone's.
//
// SHA-256 is CryptoKit's, which Linux has not, so the hash is handed in, and the tests
// there hand in RFC 7636's own.

#if canImport(CryptoKit)
import CryptoKit
#endif
import Foundation

struct PKCE: Equatable, Sendable {
    let verifier: SecretText
    let challenge: String

    init(secret: [UInt8], sha256: ([UInt8]) -> [UInt8]) {
        let verifier = Base64URL.encode(Data(secret))
        self.verifier = SecretText(verifier)
        challenge = Base64URL.encode(Data(sha256(Array(verifier.utf8))))
    }
}

#if canImport(CryptoKit)
extension PKCE {
    init(secret: [UInt8]) {
        self.init(secret: secret) { Array(SHA256.hash(data: Data($0))) }
    }

    /// A fresh pair for one sign-in. 64 bytes make an 86-character verifier, inside the
    /// RFC's 43 to 128.
    static func fresh() -> PKCE {
        PKCE(secret: (0..<64).map { _ in UInt8.random(in: .min ... .max) })
    }
}
#endif
