// Franco's list of phones that signed in with Apple and wait for him, and his yes,
// driven over a scripted gateway.

import XCTest
@testable import HouseholdAssistant

@MainActor
final class SignInApprovalsTests: XCTestCase {
    /// A connected gateway that answers each household-app method from a closure.
    @MainActor
    private final class Gateway {
        let transport = ScriptedTransport()
        let connection: GatewayConnection
        var answers: [String: (GatewayRequest) -> String] = [:]
        private(set) var signed: [String] = []

        init() {
            let store = MemoryCredentialStore(deviceToken: StoredDeviceToken(token: "t"))
            let signer = DeviceSigner(deviceId: "device-1", publicKey: "public-key") { _ in "connect-signature" }
            connection = GatewayConnection(transport: transport, credentials: store, signer: signer) { _ in
                await Task.yield()
            }
            transport.onOpen = { $0.push((try? Fixtures.text("connect-challenge")) ?? "") }
            transport.onRequest = { [weak self] transport, request in
                if request.method == "connect" {
                    transport.push((try? Fixtures.text("hello-ok-device-token", answering: request.id)) ?? "")
                } else if let answer = self?.answers[request.method] {
                    transport.push(answer(request))
                }
            }
        }

        func sign(_ text: String) -> String {
            signed.append(text)
            return "phone-signature-\(signed.count)"
        }

        func requests(_ method: String) -> [GatewayRequest] {
            transport.requests.filter { $0.method == method }
        }

        func connect() async throws {
            connection.start(GatewayConnection.Configuration(
                url: URL(string: "ws://127.0.0.1:18800")!,
                client: .stewardPhone(displayName: "test", version: "0.1.0"),
                scopes: OperatorScope.chat,
                locale: "en-US"
            ))
            var attemptsLeft = 400
            while attemptsLeft > 0, connection.state != .connected {
                try await Task.sleep(for: .milliseconds(5))
                attemptsLeft -= 1
            }
            XCTAssertEqual(connection.state, .connected)
        }
    }

    private static func ok(_ request: GatewayRequest, _ payload: String) -> String {
        #"{"type":"res","id":"\#(request.id)","ok":true,"payload":\#(payload)}"#
    }

    private static func refused(_ request: GatewayRequest, _ message: String) -> String {
        #"{"type":"res","id":"\#(request.id)","ok":false,"error":{"code":"INVALID_REQUEST","message":"\#(message)"}}"#
    }

    private static let waiting =
        #"{"waiting":[{"id":"franco-req-1","name":"New iPhone","at":1792540800000,"person":"franco"},{"id":"gia-req-1","name":"Gia's iPhone","at":1792540900000,"person":"gia"}]}"#

    private let now = Date(timeIntervalSince1970: 1_792_541_000)

    func testTheWaitingListIsWhatTheGatewaySays() async throws {
        let gateway = Gateway()
        gateway.answers["household-app.apple.waiting"] = { Self.ok($0, Self.waiting) }
        try await gateway.connect()
        let approvals = SignInApprovals(connection: gateway.connection, sign: gateway.sign, now: { self.now })

        await approvals.refresh()

        XCTAssertEqual(approvals.waiting.map(\.id), ["franco-req-1", "gia-req-1"])
        XCTAssertEqual(approvals.waiting.last, AppleSignInRequest(id: "gia-req-1", name: "Gia's iPhone", at: 1_792_540_900_000, person: "gia"))
    }

    func testAYesIsSignedByThisPhoneAndTheRequestLeavesTheList() async throws {
        let gateway = Gateway()
        gateway.answers["household-app.apple.waiting"] = { Self.ok($0, Self.waiting) }
        gateway.answers["household-app.apple.approve"] = { Self.ok($0, #"{"approved":true}"#) }
        try await gateway.connect()
        let approvals = SignInApprovals(connection: gateway.connection, sign: gateway.sign, now: { self.now })
        await approvals.refresh()

        await approvals.approve(approvals.waiting[1])

        XCTAssertEqual(gateway.signed, ["household-app/apple-approve/v1\ngia-req-1\ngia\n1792541000000"])
        let params = try XCTUnwrap(gateway.requests("household-app.apple.approve").first?.params)
        XCTAssertEqual(params, .object([
            "requestId": .string("gia-req-1"),
            "person": .string("gia"),
            "at": .number(1_792_541_000_000),
            "signature": .string("phone-signature-1"),
        ]))
        XCTAssertEqual(approvals.waiting.map(\.id), ["franco-req-1"])
        XCTAssertNil(approvals.refusal)
    }

    func testARefusedYesKeepsTheRequestAndSaysWhy() async throws {
        let gateway = Gateway()
        gateway.answers["household-app.apple.waiting"] = { Self.ok($0, Self.waiting) }
        gateway.answers["household-app.apple.approve"] = { Self.refused($0, "no such sign-in is waiting") }
        try await gateway.connect()
        let approvals = SignInApprovals(connection: gateway.connection, sign: gateway.sign, now: { self.now })
        await approvals.refresh()

        await approvals.approve(approvals.waiting[0])

        XCTAssertEqual(approvals.waiting.count, 2)
        XCTAssertEqual(approvals.refusal, "no such sign-in is waiting")
    }

    func testLinkingSendsApplesTokenWithTheGatewaysNonce() async throws {
        let gateway = Gateway()
        gateway.answers["household-app.apple.nonce"] = { Self.ok($0, #"{"nonce":"raw-nonce","expiresAtMs":1792541600000}"#) }
        gateway.answers["household-app.apple.link"] = { Self.ok($0, #"{"linked":true}"#) }
        try await gateway.connect()

        let nonce = try await gateway.connection.appleNonce()
        try await gateway.connection.appleLink(identityToken: "apple-token", nonce: nonce)

        XCTAssertEqual(nonce, "raw-nonce")
        XCTAssertEqual(gateway.requests("household-app.apple.link").first?.params, .object([
            "identityToken": .string("apple-token"),
            "nonce": .string("raw-nonce"),
        ]))
    }
}
