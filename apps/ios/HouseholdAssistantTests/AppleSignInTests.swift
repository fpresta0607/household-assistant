// Sign in with Apple, the phone's half: the three routes it calls before it is paired,
// the text Franco's phone signs to let somebody in, and his list of who is waiting.
// The gateway's half is deploy/openclaw/plugins/household-app/apple-signin.js.

import XCTest
@testable import HouseholdAssistant

@MainActor
final class AppleSignInTests: XCTestCase {
    private static let corey = URL(string: "https://household.example.ts.net:18789")!

    /// A gateway that answers each route with a status and a body, and keeps what it was sent.
    private final class Routes: @unchecked Sendable {
        var answers: [String: (Int, String)] = [:]
        private(set) var sent: [(url: URL, body: [String: String])] = []

        func post(_ url: URL, _ body: Data) throws -> (status: Int, body: Data) {
            let fields = try JSONDecoder().decode([String: String].self, from: body)
            sent.append((url, fields))
            let (status, text) = answers[url.lastPathComponent] ?? (503, "{}")
            return (status, Data(text.utf8))
        }
    }

    private func gateway(_ routes: Routes) -> AppleSignInGateway {
        AppleSignInGateway(base: Self.corey) { url, body in
            try routes.post(url, body)
        }
    }

    func testTheApprovalTextIsTheOneThePluginChecks() {
        XCTAssertEqual(
            AppleApproval.signedText(requestId: "req-1", person: "gia", at: 1_792_540_800_000),
            "household-app/apple-approve/v1\nreq-1\ngia\n1792540800000"
        )
    }

    func testEachPersonSignsInAtTheirOwnAssistantsGateway() {
        let host = HouseholdMember.gatewayHost
        XCTAssertEqual(HouseholdMember.franco.gateway.absoluteString, "https://\(host):18789")
        XCTAssertEqual(HouseholdMember.gia.gateway.absoluteString, "https://\(host):18790")
    }

    func testANonceIsAskedForAtTheGatewaysAppleRoute() async throws {
        let routes = Routes()
        routes.answers["nonce"] = (200, #"{"nonce":"raw-nonce","expiresAtMs":1792540860000}"#)
        let nonce = try await gateway(routes).nonce()
        XCTAssertEqual(nonce, "raw-nonce")
        XCTAssertEqual(routes.sent.map { $0.url.path }, ["/household-app/apple/nonce"])
    }

    func testAKnownAppleIDGetsASetupCode() async throws {
        let routes = Routes()
        routes.answers["pair"] = (200, #"{"setupCode":"the-code","expiresAtMs":1792540860000}"#)
        let answer = try await gateway(routes).pair(identityToken: "apple-token", nonce: "raw-nonce", name: "Gia's iPhone")
        XCTAssertEqual(answer, .setupCode("the-code"))
        XCTAssertEqual(routes.sent.last?.url.path, "/household-app/apple/pair")
        XCTAssertEqual(routes.sent.last?.body, ["identityToken": "apple-token", "nonce": "raw-nonce", "name": "Gia's iPhone"])
    }

    func testAnUnknownAppleIDWaitsWithATicket() async throws {
        let routes = Routes()
        routes.answers["pair"] = (200, #"{"waiting":true,"requestId":"req-1","ticket":"the-ticket"}"#)
        let answer = try await gateway(routes).pair(identityToken: "apple-token", nonce: "raw-nonce", name: "iPhone")
        XCTAssertEqual(answer, .waiting(requestId: "req-1", ticket: "the-ticket"))
    }

    func testAWaitingPhoneAsksAgainWithItsTicket() async throws {
        let routes = Routes()
        routes.answers["status"] = (200, #"{"waiting":true}"#)
        let waiting = try await gateway(routes).status(requestId: "req-1", ticket: "the-ticket")
        XCTAssertEqual(waiting, .stillWaiting)
        XCTAssertEqual(routes.sent.last?.body, ["requestId": "req-1", "ticket": "the-ticket"])
        routes.answers["status"] = (200, #"{"setupCode":"the-code","expiresAtMs":1792540860000}"#)
        let approved = try await gateway(routes).status(requestId: "req-1", ticket: "the-ticket")
        XCTAssertEqual(approved, .setupCode("the-code"))
    }

    func testTheGatewaysReasonIsKeptWhenItRefuses() async {
        let routes = Routes()
        for (status, body, expected) in [
            (400, #"{"error":"ask for a new sign-in"}"#, AppleSignInError.refused("ask for a new sign-in")),
            (429, #"{"error":"too many sign-ins, try again in a minute"}"#, .refused("too many sign-ins, try again in a minute")),
            (400, "not json", .unavailable),
            (503, #"{"error":"the household app channel is not running"}"#, .unavailable),
            (200, #"{"something":"else"}"#, .unavailable),
        ] {
            routes.answers["pair"] = (status, body)
            do {
                _ = try await gateway(routes).pair(identityToken: "t", nonce: "n", name: "iPhone")
                XCTFail("\(status) \(body) should not pair")
            } catch {
                XCTAssertEqual(error as? AppleSignInError, expected, "\(status) \(body)")
            }
        }
    }

    // MARK: - Pairing from onboarding

    /// A setup code as the gateway issues it, for Gia on Denise's gateway, good until 2100.
    private static let giasCode = Base64URL.encode(Data(
        #"{"url":"wss://household.example.ts.net:18790","bootstrapToken":"boot","expiresAtMs":4102444800000,"person":"gia","assistant":"Denise"}"#.utf8
    ))

    private func pairing(_ routes: Routes, _ credentials: MemoryCredentialStore? = nil) -> AppleSignInPairing {
        AppleSignInPairing(credentials: credentials ?? MemoryCredentialStore()) { member in
            AppleSignInGateway(base: member.gateway) { url, body in
                try routes.post(url, body)
            }
        }
    }

    func testAKnownAppleIDPairsAtOnceWithItsPersonsGateway() async throws {
        let routes = Routes()
        routes.answers["nonce"] = (200, #"{"nonce":"raw-nonce","expiresAtMs":1792540860000}"#)
        routes.answers["pair"] = (200, #"{"setupCode":"\#(Self.giasCode)","expiresAtMs":4102444800000}"#)
        let flow = pairing(routes)

        let nonce = await flow.begin(.gia)
        XCTAssertEqual(flow.phase, .idle, "ready for Apple's sheet")
        let code = await flow.finish(identityToken: "apple-token", name: "Gia's iPhone")

        XCTAssertEqual(nonce, "raw-nonce")
        XCTAssertEqual(code?.person, "gia")
        XCTAssertEqual(code?.url.absoluteString, "wss://household.example.ts.net:18790")
        XCTAssertEqual(routes.sent.map { $0.url.port }, [18790, 18790])
        XCTAssertEqual(routes.sent.last?.body["nonce"], "raw-nonce")
        XCTAssertEqual(flow.phase, .idle)
    }

    func testAnUnknownAppleIDWaitsAndTheWaitOutlivesTheApp() async throws {
        let routes = Routes()
        let credentials = MemoryCredentialStore()
        routes.answers["nonce"] = (200, #"{"nonce":"raw-nonce","expiresAtMs":1792540860000}"#)
        routes.answers["pair"] = (200, #"{"waiting":true,"requestId":"gia-req-1","ticket":"the-ticket"}"#)
        let flow = pairing(routes, credentials)

        _ = await flow.begin(.gia)
        let code = await flow.finish(identityToken: "apple-token", name: "Gia's iPhone")

        XCTAssertNil(code)
        XCTAssertEqual(flow.phase, .waiting(.gia))
        XCTAssertEqual(credentials.appleSignInWait, AppleSignInWait(member: "gia", requestId: "gia-req-1", ticket: "the-ticket"))
        XCTAssertEqual(pairing(routes, credentials).phase, .waiting(.gia))
    }

    func testAWaitingPhonePairsOnceFrancoSaysYes() async throws {
        let routes = Routes()
        let credentials = MemoryCredentialStore()
        credentials.appleSignInWait = AppleSignInWait(member: "gia", requestId: "gia-req-1", ticket: "the-ticket")
        let flow = pairing(routes, credentials)

        routes.answers["status"] = (200, #"{"waiting":true}"#)
        let early = await flow.checkWaiting()
        routes.answers["status"] = (200, #"{"setupCode":"\#(Self.giasCode)","expiresAtMs":4102444800000}"#)
        let approved = await flow.checkWaiting()

        XCTAssertNil(early)
        XCTAssertEqual(approved?.person, "gia")
        XCTAssertNil(credentials.appleSignInWait)
        XCTAssertEqual(flow.phase, .idle)
        XCTAssertEqual(routes.sent.last?.body, ["requestId": "gia-req-1", "ticket": "the-ticket"])
        XCTAssertEqual(routes.sent.last?.url.port, 18790)
    }

    func testAWaitTheGatewayNoLongerKnowsIsDroppedAndSaysWhy() async {
        let routes = Routes()
        let credentials = MemoryCredentialStore()
        credentials.appleSignInWait = AppleSignInWait(member: "gia", requestId: "gia-req-1", ticket: "the-ticket")
        routes.answers["status"] = (400, #"{"error":"no such sign-in is waiting"}"#)
        let flow = pairing(routes, credentials)

        let code = await flow.checkWaiting()

        XCTAssertNil(code)
        XCTAssertNil(credentials.appleSignInWait)
        XCTAssertEqual(flow.phase, .refused("No such sign-in is waiting."))
    }

    func testAnUnreachableGatewayKeepsTheWait() async {
        let routes = Routes()
        let credentials = MemoryCredentialStore()
        credentials.appleSignInWait = AppleSignInWait(member: "gia", requestId: "gia-req-1", ticket: "the-ticket")
        let flow = pairing(routes, credentials)

        let code = await flow.checkWaiting()

        XCTAssertNil(code)
        XCTAssertNotNil(credentials.appleSignInWait)
        XCTAssertEqual(flow.phase, .waiting(.gia))
    }

    func testARefusedSignInSaysWhyAndLeavesNoWait() async {
        let routes = Routes()
        let credentials = MemoryCredentialStore()
        routes.answers["nonce"] = (200, #"{"nonce":"raw-nonce","expiresAtMs":1792540860000}"#)
        routes.answers["pair"] = (429, #"{"error":"too many sign-ins, try again in a minute"}"#)
        let flow = pairing(routes, credentials)

        _ = await flow.begin(.franco)
        let code = await flow.finish(identityToken: "apple-token", name: "iPhone")

        XCTAssertNil(code)
        XCTAssertNil(credentials.appleSignInWait)
        XCTAssertEqual(flow.phase, .refused("Too many sign-ins, try again in a minute."))
    }

    func testAnUnreachableGatewaySaysToCheckTailscale() async {
        let flow = pairing(Routes())
        let nonce = await flow.begin(.franco)
        XCTAssertNil(nonce)
        XCTAssertEqual(flow.phase, .refused("Your assistant could not be reached. Check that Tailscale is on for this iPhone."))
    }

    func testFinishingWithoutANonceSendsNothing() async {
        let routes = Routes()
        let flow = pairing(routes)
        let code = await flow.finish(identityToken: "apple-token", name: "iPhone")
        XCTAssertNil(code)
        XCTAssertTrue(routes.sent.isEmpty)
        XCTAssertEqual(flow.phase, .refused("Sign in with Apple again."))
    }

    func testGivingUpForgetsTheTicket() {
        let credentials = MemoryCredentialStore()
        credentials.appleSignInWait = AppleSignInWait(member: "gia", requestId: "gia-req-1", ticket: "the-ticket")
        let flow = pairing(Routes(), credentials)
        flow.giveUp()
        XCTAssertNil(credentials.appleSignInWait)
        XCTAssertEqual(flow.phase, .idle)
    }
}
