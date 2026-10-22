// The connection's state machine, driven by the frames the live gateway sent.

import XCTest
@testable import HouseholdAssistant

@MainActor
final class GatewayConnectionTests: XCTestCase {
    private let configuration = GatewayConnection.Configuration(
        url: URL(string: "ws://127.0.0.1:18800")!,
        client: .stewardPhone(displayName: "test", version: "0.1.0"),
        scopes: OperatorScope.chat,
        locale: "en-US"
    )
    private var signedPayloads: [String] = []

    private func makeConnection(
        _ transport: ScriptedTransport,
        _ store: MemoryCredentialStore,
        sleep: @escaping (Double) async throws -> Void = { _ in await Task.yield() },
        now: @escaping () -> Date = { Date() }
    ) -> GatewayConnection {
        let signer = DeviceSigner(deviceId: "device-1", publicKey: "public-key") { payload in
            self.signedPayloads.append(payload)
            return "signature"
        }
        return GatewayConnection(
            transport: transport,
            credentials: store,
            signer: signer,
            sleep: sleep,
            now: now
        )
    }

    private func eventually(
        _ what: String,
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        var attemptsLeft = 400
        while attemptsLeft > 0, !condition() {
            try? await Task.sleep(for: .milliseconds(5))
            attemptsLeft -= 1
        }
        XCTAssertTrue(condition(), "timed out waiting for: \(what)", file: file, line: line)
    }

    /// A gateway that challenges on open and answers `connect` with a fixture.
    private func script(_ transport: ScriptedTransport, connectAnswers: [String]) {
        var remaining = connectAnswers
        transport.onOpen = { transport in
            transport.push((try? Fixtures.text("connect-challenge")) ?? "")
        }
        transport.onRequest = { transport, request in
            guard request.method == "connect" else {
                return
            }
            let name = remaining.count > 1 ? remaining.removeFirst() : remaining[0]
            transport.push((try? Fixtures.text(name, answering: request.id)) ?? "")
        }
    }

    /// A gateway that promises a `tick` every `milliseconds` and never sends one.
    private func scriptSilentTicks(_ transport: ScriptedTransport, everyMilliseconds milliseconds: Int) {
        transport.onOpen = { $0.push((try? Fixtures.text("connect-challenge")) ?? "") }
        transport.onRequest = { transport, request in
            guard request.method == "connect" else {
                return
            }
            let text = try? Fixtures.text("hello-ok-device-token", answering: request.id) { frame in
                guard var payload = frame["payload"] as? [String: Any], var policy = payload["policy"] as? [String: Any] else {
                    return
                }
                policy["tickIntervalMs"] = milliseconds
                payload["policy"] = policy
                frame["payload"] = payload
            }
            transport.push(text ?? "")
        }
    }

    /// A gateway that refuses every `connect` with a scope mismatch.
    private func refuseTheScopes(_ transport: ScriptedTransport) {
        transport.onOpen = { $0.push((try? Fixtures.text("connect-challenge")) ?? "") }
        transport.onRequest = { transport, request in
            transport.push(#"{"type":"res","id":"\#(request.id)","ok":false,"error":{"code":"INVALID_REQUEST","message":"scope mismatch","details":{"code":"AUTH_SCOPE_MISMATCH"}}}"#)
        }
    }

    /// Siri starts the app with no screen and asks at once, so a connect has to
    /// be visible as soon as `start` returns, before anything is awaited.
    func testStartShowsAConnectIsInFlightWithoutAwaiting() {
        let transport = ScriptedTransport()
        let store = MemoryCredentialStore(deviceToken: StoredDeviceToken(token: "t"))
        let connection = makeConnection(transport, store)

        connection.start(configuration)
        XCTAssertEqual(connection.state, .connecting)
        XCTAssertTrue(connection.state.isComingUp)

        connection.stop()
        XCTAssertEqual(connection.state, .disconnected)
        XCTAssertFalse(connection.state.isComingUp)
    }

    func testWithNoCredentialItAsksToBePaired() async {
        let transport = ScriptedTransport()
        let connection = makeConnection(transport, MemoryCredentialStore())
        connection.start(configuration)
        await eventually("needs pairing") {
            if case .needsPairing = connection.state { return true }
            return false
        }
        XCTAssertEqual(transport.openCount, 0)
    }

    /// A setup code pairs the phone as a mobile node, which OpenClaw approves on its
    /// own, and hands back an operator token beside the node one. The phone keeps
    /// only the operator token and comes straight back as the operator with it.
    func testASetupCodePairsAsANodeThenConnectsAsTheOperator() async throws {
        let transport = ScriptedTransport()
        let store = MemoryCredentialStore(bootstrapToken: "setup-secret")
        transport.onOpen = { $0.push((try? Fixtures.text("connect-challenge")) ?? "") }
        transport.onRequest = { transport, request in
            guard request.method == "connect" else {
                return
            }
            // The operator's connect is answered the way a paired phone's is, echoing its token.
            let isSetup = request.params["auth"]?["bootstrapToken"] != nil
            let text = try? Fixtures.text(isSetup ? "hello-ok-bootstrap" : "hello-ok-device-token", answering: request.id) { frame in
                guard !isSetup, var payload = frame["payload"] as? [String: Any], var auth = payload["auth"] as? [String: Any] else {
                    return
                }
                auth["deviceToken"] = "REDACTED-OPERATOR"
                payload["auth"] = auth
                frame["payload"] = payload
            }
            transport.push(text ?? "")
        }
        let connection = makeConnection(transport, store)

        connection.start(configuration)
        await eventually("connected") { connection.state == .connected && transport.openCount == 2 }

        XCTAssertEqual(store.deviceToken?.token, "REDACTED-OPERATOR")
        XCTAssertNil(store.bootstrapToken)

        let setup = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(setup.params["auth"], .object(["bootstrapToken": .string("setup-secret")]))
        XCTAssertEqual(setup.params["role"], .string("node"))
        XCTAssertEqual(setup.params["scopes"], .array([]))
        XCTAssertEqual(setup.params["client"]?["id"], .string("openclaw-ios"))
        XCTAssertEqual(setup.params["client"]?["mode"], .string("node"))
        XCTAssertEqual(setup.params["client"]?["platform"], .string("ios"))
        XCTAssertEqual(setup.params["client"]?["deviceFamily"], .string("iphone"))
        // The device signature is bound to the setup code's token, as the gateway checks.
        XCTAssertEqual(
            signedPayloads.first,
            "v3|device-1|openclaw-ios|node|node||1789787358959|setup-secret|01379a3a-340d-4a69-973f-0566ca4f92b8|ios|iphone"
        )

        let operatorConnect = try XCTUnwrap(transport.requests.last { $0.method == "connect" })
        XCTAssertEqual(operatorConnect.params["auth"], .object(["deviceToken": .string("REDACTED-OPERATOR")]))
        XCTAssertEqual(operatorConnect.params["role"], .string("operator"))
        XCTAssertEqual(operatorConnect.params["scopes"], .array(OperatorScope.chat.map(JSONValue.string)))
        XCTAssertEqual(operatorConnect.params["client"]?["mode"], .string("ui"))
        connection.stop()
    }

    func testARejectedSetupCodeAsksForANewOne() async {
        let transport = ScriptedTransport()
        let store = MemoryCredentialStore(bootstrapToken: "used-already")
        transport.onOpen = { $0.push((try? Fixtures.text("connect-challenge")) ?? "") }
        transport.onRequest = { transport, request in
            transport.push(#"{"type":"res","id":"\#(request.id)","ok":false,"error":{"code":"INVALID_REQUEST","message":"unauthorized: setup code invalid, expired, revoked, or already used","details":{"code":"AUTH_BOOTSTRAP_TOKEN_INVALID"}}}"#)
        }
        let connection = makeConnection(transport, store)

        connection.start(configuration)
        await eventually("needs pairing") {
            if case .needsPairing = connection.state { return true }
            return false
        }

        XCTAssertEqual(connection.state, .needsPairing(message: "That code has expired or was already used. Get a new one."))
        XCTAssertNil(store.bootstrapToken)
        XCTAssertEqual(transport.openCount, 1)
    }

    /// A gateway that pairs the phone but hands back no operator token has left it
    /// with nothing to chat with, so the phone asks for a new code rather than looping.
    func testASetupWithoutAnOperatorTokenAsksForANewCode() async {
        let transport = ScriptedTransport()
        let store = MemoryCredentialStore(bootstrapToken: "setup-secret")
        transport.onOpen = { $0.push((try? Fixtures.text("connect-challenge")) ?? "") }
        transport.onRequest = { transport, request in
            let text = try? Fixtures.text("hello-ok-bootstrap", answering: request.id) { frame in
                guard var payload = frame["payload"] as? [String: Any], var auth = payload["auth"] as? [String: Any] else {
                    return
                }
                auth["deviceTokens"] = nil
                payload["auth"] = auth
                frame["payload"] = payload
            }
            transport.push(text ?? "")
        }
        let connection = makeConnection(transport, store)

        connection.start(configuration)
        await eventually("needs pairing") {
            if case .needsPairing = connection.state { return true }
            return false
        }

        XCTAssertNil(store.deviceToken)
        XCTAssertNil(store.bootstrapToken)
        XCTAssertEqual(transport.openCount, 1)
    }

    func testApprovalPendingIsShownWithItsRequestId() async {
        let transport = ScriptedTransport()
        script(transport, connectAnswers: ["connect-refused-pairing-required"])
        let connection = makeConnection(transport, MemoryCredentialStore(bootstrapToken: "s"))

        connection.start(configuration)
        await eventually("pairing pending") {
            if case .pairingPending(let requestId) = connection.state { return requestId != nil }
            return false
        }
        await eventually("it keeps knocking") { transport.openCount >= 3 }
        connection.stop()
        XCTAssertEqual(connection.state, .disconnected)
    }

    func testAPairedPhoneConnectsWithItsDeviceToken() async throws {
        let transport = ScriptedTransport()
        let store = MemoryCredentialStore(deviceToken: StoredDeviceToken(token: "device-token"))
        script(transport, connectAnswers: ["hello-ok-device-token"])
        let connection = makeConnection(transport, store)

        connection.start(configuration)
        await eventually("connected") { connection.state == .connected }

        let connect = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(connect.params["auth"], .object(["deviceToken": .string("device-token")]))
        XCTAssertEqual(connect.params["minProtocol"], .number(4))
        XCTAssertEqual(connect.params["client"]?["id"]?.stringValue, "openclaw-ios")
        connection.stop()
    }

    func testAScopeMismatchDiscardsTheDeviceTokenAndAsksToPairAgain() async {
        let transport = ScriptedTransport()
        let store = MemoryCredentialStore(deviceToken: StoredDeviceToken(token: "stale"))
        refuseTheScopes(transport)
        let connection = makeConnection(transport, store)

        connection.start(configuration)
        await eventually("needs pairing") {
            if case .needsPairing = connection.state { return true }
            return false
        }
        XCTAssertNil(store.deviceToken)
    }

    func testRequestsResolveAndEventsAreDelivered() async throws {
        let transport = ScriptedTransport()
        let store = MemoryCredentialStore(deviceToken: StoredDeviceToken(token: "t"))
        script(transport, connectAnswers: ["hello-ok-device-token"])
        let answerConnect = transport.onRequest
        transport.onRequest = { transport, request in
            answerConnect?(transport, request)
            if request.method == "agent.identity.get" {
                // An event the app ignores arrives in between, as it does live.
                transport.push((try? Fixtures.text("event-agent-ignored")) ?? "")
                transport.push((try? Fixtures.text("agent-identity-response", answering: request.id)) ?? "")
            }
            if request.method == "skills.status" {
                transport.push((try? Fixtures.text("error-missing-scope", answering: request.id)) ?? "")
            }
        }
        let connection = makeConnection(transport, store)
        var events: [String] = []
        connection.onEvent = { events.append($0.event) }

        connection.start(configuration)
        await eventually("connected") { connection.state == .connected }

        let identity = try await connection.agentIdentity()
        XCTAssertEqual(identity.agentId, "main")
        XCTAssertEqual(events, ["agent"])

        do {
            _ = try await connection.request("skills.status")
            XCTFail("expected the gateway's refusal")
        } catch let error as GatewayErrorShape {
            XCTAssertEqual(error.detailCode, "MISSING_SCOPE")
        }
        connection.stop()
    }

    /// The main actor is handed every frame ready to use: none is read or decoded on the
    /// main thread, an answer comes as the model its request wants, and a streamed piece of
    /// a reply as its own model.
    func testEveryFrameIsReadAndDecodedAwayFromTheMainThread() async throws {
        // Arrange
        let transport = ScriptedTransport()
        let store = MemoryCredentialStore(deviceToken: StoredDeviceToken(token: "t"))
        script(transport, connectAnswers: ["hello-ok-device-token"])
        let answerConnect = transport.onRequest
        transport.onRequest = { transport, request in
            answerConnect?(transport, request)
            if request.method == "household-app.sync" {
                transport.push((try? Fixtures.text("chat-event-delta")) ?? "")
                transport.push((try? Fixtures.text("household-app-sync-response", answering: request.id)) ?? "")
            }
        }
        let connection = makeConnection(transport, store)
        var events: [GatewayEvent] = []
        connection.onEvent = { events.append($0) }
        connection.start(configuration)
        await eventually("connected") { connection.state == .connected }

        // Act
        let page = try await connection.roomSync(since: 0)

        // Assert
        XCTAssertEqual(page.rev, 6)
        XCTAssertEqual(page.entries.count, 6)
        guard case .chat(let chat)? = events.first?.body else {
            return XCTFail("the streamed piece did not arrive as a chat event: \(events)")
        }
        XCTAssertEqual(chat.state, .delta)
        XCTAssertGreaterThanOrEqual(transport.reads, 4, "the challenge, hello-ok, the piece and the page")
        XCTAssertEqual(transport.readsOnMainThread, 0)
        connection.stop()
    }

    /// A payload that does not read as the model its request wants fails the request as it
    /// arrives, as decoding it on the main actor used to, rather than after the timeout.
    func testAnAnswerThatDoesNotReadAsItsModelFailsItsRequestAtOnce() async throws {
        // Arrange
        let transport = ScriptedTransport()
        let store = MemoryCredentialStore(deviceToken: StoredDeviceToken(token: "t"))
        script(transport, connectAnswers: ["hello-ok-device-token"])
        let answerConnect = transport.onRequest
        transport.onRequest = { transport, request in
            answerConnect?(transport, request)
            if request.method == "household-app.sync" {
                transport.push(#"{"type":"res","id":"\#(request.id)","ok":true,"payload":{"rev":"six"}}"#)
            }
        }
        let connection = makeConnection(transport, store)
        connection.start(configuration)
        await eventually("connected") { connection.state == .connected }

        // Act
        let clock = ContinuousClock()
        let started = clock.now
        do {
            _ = try await connection.roomSync(since: 0)
            XCTFail("expected the page not to read")
        } catch {
            // Assert
            XCTAssertTrue(error is DecodingError, "\(error)")
        }
        XCTAssertLessThan(clock.now - started, .seconds(GatewayConnection.requestTimeoutSeconds))
        connection.stop()
    }

    func testADroppedLinkFailsWaitingRequestsAndReconnects() async throws {
        let transport = ScriptedTransport()
        let store = MemoryCredentialStore(deviceToken: StoredDeviceToken(token: "t"))
        script(transport, connectAnswers: ["hello-ok-device-token"])
        let connection = makeConnection(transport, store)

        connection.start(configuration)
        await eventually("connected") { connection.state == .connected }

        async let unanswered = connection.request("chat.history", .object(["sessionKey": .string("k")]))
        await eventually("request sent") { transport.requests.contains { $0.method == "chat.history" } }
        transport.drop()
        do {
            _ = try await unanswered
            XCTFail("expected the request to fail")
        } catch {
            XCTAssertEqual(error as? GatewayConnectionError, .notConnected)
        }

        await eventually("reconnected") { connection.state == .connected && transport.openCount == 2 }
        connection.stop()
    }

    /// When iOS says the network is back, a link waiting to try again tries at once rather
    /// than waiting out a delay that grows to half a minute.
    func testALinkWaitingToTryAgainTriesAtOnceWhenTheNetworkIsBack() async {
        // Arrange
        let transport = ScriptedTransport()
        script(transport, connectAnswers: ["hello-ok-device-token", "hello-ok-device-token"])
        let connection = makeConnection(
            transport,
            MemoryCredentialStore(deviceToken: StoredDeviceToken(token: "t")),
            sleep: { _ in try await Task.sleep(for: .seconds(3600)) }
        )
        connection.start(configuration)
        await eventually("connected") { connection.state == .connected }
        transport.drop()
        await eventually("waiting to try again") {
            if case .reconnecting = connection.state {
                return true
            }
            return false
        }

        // Act
        connection.retryNow()

        // Assert
        await eventually("tried again at once") { connection.state == .connected && transport.openCount == 2 }
        connection.stop()
    }

    /// No tick for well over two intervals is a dead link TCP has not noticed: the phone
    /// gives it up and opens another.
    func testASilentLinkIsGivenUpAndOpenedAgain() async {
        let transport = ScriptedTransport()
        scriptSilentTicks(transport, everyMilliseconds: 100)
        let connection = makeConnection(transport, MemoryCredentialStore(deviceToken: StoredDeviceToken(token: "t")))

        connection.start(configuration)
        await eventually("connected") { connection.state == .connected }
        await eventually("given up and opened again") { transport.openCount >= 2 }

        connection.stop()
    }

    /// iOS suspends an app in the background, and the watcher's next look comes only once it
    /// is back, long after it asked, with the gateway's ticks still unread in the socket.
    /// That time is not silence: the link is kept, and judged from the return on.
    func testTimeTheAppSpentSuspendedIsNotSilence() async throws {
        let transport = ScriptedTransport()
        // Looks every 200 milliseconds, and gives up after 500 of silence.
        scriptSilentTicks(transport, everyMilliseconds: 200)
        var suspended: TimeInterval = 0
        let connection = makeConnection(transport, MemoryCredentialStore(deviceToken: StoredDeviceToken(token: "t"))) {
            Date().addingTimeInterval(suspended)
        }

        connection.start(configuration)
        await eventually("connected") { connection.state == .connected }
        // Ten minutes in the background pass before the watcher's first look.
        suspended = 600
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(transport.openCount, 1, "a live link was dropped for the time the app was away")
        XCTAssertEqual(connection.state, .connected)

        // Silent still after the return, it is given up once its full term has passed.
        await eventually("given up after the return") { transport.openCount >= 2 }
        connection.stop()
    }
}
