// Every frame captured from the live gateway decodes, and the ones the app
// acts on decode into what the app expects.

import XCTest
@testable import HouseholdAssistant

final class FixtureDecodingTests: XCTestCase {
    func testEveryFixtureDecodesAsAFrame() throws {
        let names = try Fixtures.allNames()
        XCTAssertGreaterThanOrEqual(names.count, 15)
        for name in names {
            XCTAssertNoThrow(try GatewayCodec.decode(try Fixtures.text(name)), name)
        }
    }

    func testChallengeCarriesNonceAndTimestamp() throws {
        guard case .event(let event) = try GatewayCodec.decode(try Fixtures.text("connect-challenge")) else {
            return XCTFail("not an event")
        }
        XCTAssertEqual(event.event, "connect.challenge")
        let challenge = try XCTUnwrap(event.payload).decoded(as: ConnectChallenge.self)
        XCTAssertFalse(challenge.nonce.isEmpty)
        XCTAssertGreaterThan(challenge.ts, 1_700_000_000_000)
    }

    func testPairingRequiredCarriesTheRequestId() throws {
        let error = try XCTUnwrap(response("connect-refused-pairing-required").error)
        XCTAssertEqual(error.code, "NOT_PAIRED")
        XCTAssertEqual(error.detailCode, "PAIRING_REQUIRED")
        XCTAssertEqual(
            ConnectFailure.classify(error),
            .waitForApproval(requestId: error.pairingRequestId)
        )
        XCTAssertNotNil(error.pairingRequestId)
    }

    func testHelloOkWithDeviceToken() throws {
        let hello = try XCTUnwrap(response("hello-ok-device-token").payload).decoded(as: HelloOk.self)
        XCTAssertEqual(hello.protocolVersion, ConnectRequest.protocolVersion)
        XCTAssertEqual(hello.auth.role, ConnectRequest.role)
        XCTAssertNotNil(hello.auth.deviceToken)
        XCTAssertEqual(hello.policy.tickIntervalMs, 30_000)
        XCTAssertEqual(hello.snapshot.sessionDefaults.mainSessionKey, "agent:main:main")
        for method in ["chat.send", "chat.history", "agent.identity.get", "skills.status"] {
            XCTAssertTrue(hello.features.methods.contains(method), method)
        }
        XCTAssertTrue(hello.features.events.contains("chat"))
    }

    /// Made by hand from OpenClaw's handshake docs and the captured hello-ok, since
    /// no phone had paired with a setup code when it was written: the node token
    /// the setup code earns, with the bounded operator token beside it.
    func testHelloOkFromASetupCodeCarriesTheOperatorToken() throws {
        let hello = try XCTUnwrap(response("hello-ok-bootstrap").payload).decoded(as: HelloOk.self)
        XCTAssertEqual(hello.auth.role, ConnectRequest.setupRole)
        XCTAssertEqual(hello.auth.deviceTokens, [HelloOk.IssuedToken(deviceToken: "REDACTED-OPERATOR", role: ConnectRequest.role)])
    }

    func testHelloOkWithoutADeviceIssuesNoToken() throws {
        let hello = try XCTUnwrap(response("hello-ok-token-only").payload).decoded(as: HelloOk.self)
        XCTAssertNil(hello.auth.deviceToken)
    }

    /// An answer whose request said which model it wants is read from the frame straight
    /// into it, with no JSON in between; an answer nobody asked for a model of stays JSON.
    func testAnAnswerIsReadStraightIntoTheModelItsRequestWants() throws {
        // Arrange
        let answerTypes = GatewayAnswerTypes()
        answerTypes.expect(RoomSyncPage.self, for: "fixture-sync")
        let text = try Fixtures.text("household-app-sync-response", answering: "fixture-sync")
        let other = try Fixtures.text("household-app-sync-response", answering: "another-request")

        // Act
        guard
            case .response(let wanted) = try GatewayCodec.decode(text, answerTypes: answerTypes),
            case .response(let unwanted) = try GatewayCodec.decode(other, answerTypes: answerTypes)
        else {
            return XCTFail("not a response")
        }

        // Assert
        guard case .model(let page as RoomSyncPage) = wanted.body else {
            return XCTFail("not read into its model: \(wanted.body)")
        }
        XCTAssertEqual(page, try XCTUnwrap(unwanted.payload).decoded(as: RoomSyncPage.self))
        XCTAssertNil(wanted.payload)
    }

    func testRoomEventsAreReadStraightIntoTheirModels() throws {
        for name in ["household-app-changed-event", "household-app-typing-event"] {
            // Act
            guard case .event(let event) = try GatewayCodec.decode(try Fixtures.text(name)) else {
                return XCTFail("\(name) is not an event")
            }

            // Assert
            guard case .room = event.body else {
                return XCTFail("\(name) was not read into its model: \(event.body)")
            }
            XCTAssertNil(event.payload, name)
        }
    }

    func testMissingScopeError() throws {
        let error = try XCTUnwrap(response("error-missing-scope").error)
        XCTAssertEqual(error.code, "FORBIDDEN")
        XCTAssertEqual(error.detailCode, "MISSING_SCOPE")
    }

    func testIdentityComesFromTheGateway() throws {
        let identity = try XCTUnwrap(response("agent-identity-response").payload).decoded(as: AgentIdentity.self)
        XCTAssertEqual(identity.agentId, "main")
        XCTAssertFalse(try XCTUnwrap(identity.name).isEmpty)
        XCTAssertFalse(try XCTUnwrap(identity.emoji).isEmpty)
    }

    func testChatEventsDecodeInEveryCapturedState() throws {
        let expected: [(String, ChatEvent.State)] = [
            ("chat-event-status", .status),
            ("chat-event-delta", .delta),
            ("chat-event-final", .final),
        ]
        for (name, state) in expected {
            let chat = try chatEvent(name)
            XCTAssertEqual(chat.state, state, name)
            XCTAssertEqual(chat.sessionKey, "agent:main:steward-ios-v1-probe")
        }
        XCTAssertFalse(try XCTUnwrap(try chatEvent("chat-event-delta").deltaText).isEmpty)
    }

    func testTheConnectRequestWeBuildMatchesTheOneTheGatewayAccepted() throws {
        let accepted = try JSONDecoder().decode(
            GatewayRequest.self,
            from: Data(try Fixtures.text("connect-request-device-token").utf8)
        )
        let device = try XCTUnwrap(accepted.params["device"])
        let built = ConnectRequest.make(
            id: accepted.id,
            challenge: ConnectChallenge(
                nonce: try XCTUnwrap(device["nonce"]?.stringValue),
                ts: try XCTUnwrap(device["signedAt"]?.intValue)
            ),
            client: .stewardPhone(displayName: "steward-ios-v1 protocol probe", version: "0.1.0"),
            scopes: OperatorScope.chat,
            credential: ConnectRequest.Credential(kind: .deviceToken, value: "REDACTED"),
            device: ConnectRequest.SignedDevice(
                id: try XCTUnwrap(device["id"]?.stringValue),
                publicKey: try XCTUnwrap(device["publicKey"]?.stringValue),
                signature: "REDACTED"
            ),
            locale: "en-US"
        )
        XCTAssertEqual(built, accepted)
    }

    func testARequestSurvivesEncodingWithWholeNumbersAsIntegers() throws {
        let text = try GatewayCodec.encode(GatewayRequest(id: "1", method: "m", params: .object(["signedAt": .number(1_789_786_920_945)])))
        XCTAssertTrue(text.contains("1789786920945"), text)
        XCTAssertFalse(text.contains("1789786920945."), text)
        XCTAssertFalse(text.contains("e+"), text)
    }

    private func response(_ name: String) throws -> GatewayResponse {
        guard case .response(let response) = try GatewayCodec.decode(try Fixtures.text(name)) else {
            XCTFail("\(name) is not a response")
            throw GatewayConnectionError.unexpectedFrame
        }
        return response
    }

    /// A chat event is read straight from its frame into its model, with no JSON kept.
    private func chatEvent(_ name: String) throws -> ChatEvent {
        guard case .event(let event) = try GatewayCodec.decode(try Fixtures.text(name)), case .chat(let chat) = event.body else {
            XCTFail("\(name) is not a chat event")
            throw GatewayConnectionError.unexpectedFrame
        }
        XCTAssertNil(event.payload, name)
        return chat
    }
}
