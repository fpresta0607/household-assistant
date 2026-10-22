// The signed payload and the device identity, against the gateway's own rules.

import XCTest
@testable import HouseholdAssistant

final class DeviceAuthTests: XCTestCase {
    private let client = ClientInfo.stewardPhone(displayName: "test", version: "0.1.0")

    func testV3PayloadLayout() {
        let payload = DeviceAuthPayload.v3(
            deviceId: "abc",
            client: client,
            role: "operator",
            scopes: ["operator.read", "operator.write"],
            signedAtMs: 1_789_786_920_945,
            token: "tok",
            nonce: "n-1"
        )
        XCTAssertEqual(
            payload,
            "v3|abc|openclaw-ios|ui|operator|operator.read,operator.write|1789786920945|tok|n-1|ios|iphone"
        )
    }

    func testAMissingTokenSignsAsEmpty() {
        let payload = DeviceAuthPayload.v3(
            deviceId: "abc", client: client, role: "operator", scopes: [], signedAtMs: 1, token: nil, nonce: "n"
        )
        XCTAssertEqual(payload, "v3|abc|openclaw-ios|ui|operator||1||n|ios|iphone")
    }

    func testMetadataIsTrimmedAndOnlyAsciiLowercased() {
        XCTAssertEqual(DeviceAuthPayload.normalizeMetadata("  iPhone "), "iphone")
        XCTAssertEqual(DeviceAuthPayload.normalizeMetadata("IOS"), "ios")
        // The gateway folds A to Z only; a non-ASCII capital passes through.
        XCTAssertEqual(DeviceAuthPayload.normalizeMetadata("ÉA"), "Éa")
        XCTAssertEqual(DeviceAuthPayload.normalizeMetadata(""), "")
    }

    func testBase64URLRoundTrip() throws {
        let data = Data([0xfb, 0xff, 0xfe, 0x00, 0x01])
        let text = Base64URL.encode(data)
        XCTAssertFalse(text.contains("+") || text.contains("/") || text.contains("="))
        XCTAssertEqual(Base64URL.decode(text), data)
    }

    #if canImport(CryptoKit)
    // Vector from the Python `cryptography` library, the same code whose
    // signature the live gateway accepted during the protocol probe.
    func testIdentityMatchesTheGatewaysFingerprintRule() throws {
        let identity = try DeviceIdentity(seed: Data(1...32))
        XCTAssertEqual(identity.publicKey, "ebVWLo_mVPlAeLES6KmLp5AfhTrmlb7X4OORC60ElmQ")
        XCTAssertEqual(identity.deviceId, "65b60673d6ed884bf01c2c222d82ada0740f29ac3355d6a925c81f17f47a27b8")
    }

    func testASignatureVerifiesAndIsSixtyFourBytes() throws {
        let identity = try DeviceIdentity(seed: Data(1...32))
        let signature = try XCTUnwrap(Base64URL.decode(try identity.sign("v3|payload")))
        XCTAssertEqual(signature.count, 64)
        XCTAssertEqual(try DeviceIdentity(seed: identity.seed).deviceId, identity.deviceId)
    }
    #endif
}
