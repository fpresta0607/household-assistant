// The small pure rules: addresses, setup codes, backoff, refusals, symbols, levels.

import XCTest
@testable import HouseholdAssistant

final class SmallRulesTests: XCTestCase {
    func testGatewayAddressAcceptsWhatPeopleType() {
        let accepted: [(String, String)] = [
            // The tailnet address as the box publishes it: HTTPS only, so a
            // bare `host:port` has to become `wss://` or the phone never connects.
            ("gateway.tail1234.ts.net:18789", "wss://gateway.tail1234.ts.net:18789"),
            ("box:18800", "wss://box:18800"),
            ("  127.0.0.1:18800 ", "wss://127.0.0.1:18800"),
            ("ws://box:18800", "ws://box:18800"),
            ("wss://box.example.ts.net", "wss://box.example.ts.net"),
            ("WS://box:1", "WS://box:1"),
        ]
        for (input, expected) in accepted {
            XCTAssertEqual(GatewayAddress.url(from: input)?.absoluteString, expected, input)
        }
        for input in ["", "   ", "https://box", "ws://", "ftp://box:1"] {
            XCTAssertNil(GatewayAddress.url(from: input), input)
        }
    }

    /// A setup code as Corey or Denise sends it: unpadded base64url of its JSON.
    private func setupCode(_ fields: [String: Any]) throws -> String {
        Base64URL.encode(try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]))
    }

    private let now = Date(timeIntervalSince1970: 1_792_050_000)

    private var coreysFields: [String: Any] {
        [
            "url": "wss://household.example.ts.net:18789",
            "bootstrapToken": "single-use",
            "expiresAtMs": 1_792_050_300_000,
            "access": "limited",
            "person": "franco",
            "assistant": "Corey",
        ]
    }

    func testASetupCodeIsReadFromTheCodeTheLinkOrTheWholeMessage() throws {
        let code = try setupCode(coreysFields)
        let message = "Here is your Steward AI code. Tap it to copy, then paste it in the app.\n\n\(code)\n\nIt works once, for 10 minutes."
        for text in [code, "  \(code)\n", "steward://pair?code=\(code)", message] {
            let pairing = try XCTUnwrap(PairingCode(text: text, now: now), text)
            XCTAssertEqual(pairing.url.absoluteString, "wss://household.example.ts.net:18789")
            XCTAssertEqual(pairing.bootstrapToken, "single-use")
            XCTAssertEqual(pairing.person, "franco")
            XCTAssertEqual(pairing.assistant, "Corey")
        }
    }

    /// OpenClaw's own setup codes carry no person or assistant, and are just as good.
    func testOpenClawsOwnSetupCodeIsAccepted() throws {
        let code = try setupCode([
            "url": "wss://household.example.ts.net:18790",
            "bootstrapToken": "single-use",
            "expiresAtMs": 1_792_050_300_000,
            "access": "full",
        ])
        let pairing = try XCTUnwrap(PairingCode(text: code, now: now))
        XCTAssertNil(pairing.person)
        XCTAssertNil(pairing.assistant)
    }

    func testWhatIsNotAUsableSetupCodeIsRefused() throws {
        var expired = coreysFields
        expired["expiresAtMs"] = 1_792_049_999_000
        var web = coreysFields
        web["url"] = "https://household.example.ts.net:18789"
        var tokenless = coreysFields
        tokenless["bootstrapToken"] = ""
        var addressless = coreysFields
        addressless["url"] = nil
        let refused = [
            "",
            "hello",
            "https://example.com",
            "steward://pair",
            "steward://pair?code=",
            try setupCode(expired),
            try setupCode(web),
            try setupCode(tokenless),
            try setupCode(addressless),
            Base64URL.encode(Data("not json at all".utf8)),
        ]
        for text in refused {
            XCTAssertNil(PairingCode(text: text, now: now), text)
        }
    }

    func testEachPersonIsSentToTheirOwnAssistantInTelegram() {
        XCTAssertEqual(HouseholdMember.franco.assistantName, "Corey")
        XCTAssertEqual(HouseholdMember.gia.assistantName, "Denise")
        XCTAssertEqual(HouseholdMember.franco.telegramLink.absoluteString, "https://t.me/Corey_the_man_bot?text=%2Fapp")
        XCTAssertEqual(HouseholdMember.gia.telegramLink.absoluteString, "https://t.me/Denise_the_woman_bot?text=%2Fapp")
    }

    func testOnlyPermissionsIOSHasNotAskedAboutAreOffered() {
        XCTAssertEqual(PermissionKind.toOffer([:]), [.notifications, .voice, .location])
        XCTAssertEqual(
            PermissionKind.toOffer([.notifications: .allowed, .voice: .notAsked, .location: .denied]),
            [.voice]
        )
        XCTAssertEqual(PermissionKind.toOffer([.notifications: .denied, .voice: .allowed, .location: .allowed]), [])
    }

    /// Voice needs the microphone and speech recognition, so it is settled only when both are.
    func testVoiceIsSettledOnlyWhenTheMicrophoneAndSpeechBothAre() {
        XCTAssertEqual(PermissionStatus.combined([.allowed, .notAsked]), .notAsked)
        XCTAssertEqual(PermissionStatus.combined([.allowed, .allowed]), .allowed)
        XCTAssertEqual(PermissionStatus.combined([.allowed, .denied]), .denied)
        XCTAssertEqual(PermissionStatus.combined([.denied, .notAsked]), .notAsked)
    }

    func testBackoffDoublesThenHoldsAtThirtySeconds() {
        XCTAssertEqual((1...8).map(ReconnectPolicy.delaySeconds(forAttempt:)), [1, 2, 4, 8, 16, 30, 30, 30])
        XCTAssertEqual(ReconnectPolicy.delaySeconds(forAttempt: 0), 1)
    }

    /// Under this phone's person on Settings and Account: a link that is up has no word, since
    /// the green dot says it, and every other state still says where the link stands.
    func testTheLineUnderThisPhonesPersonLeavesConnectedToTheGreenDot() {
        let cases: [(state: ConnectionState, assistant: String?, line: String)] = [
            (.connected, "Corey", "Paired with Corey"),
            (.connected, nil, "Not paired"),
            (.connecting, "Corey", "Paired with Corey \u{00B7} connecting"),
            (.reconnecting(attempt: 2), "Corey", "Paired with Corey \u{00B7} reconnecting"),
            (.pairingPending(requestId: nil), "Corey", "Waiting for approval on the server"),
            (.needsPairing(message: "Enter a new setup code."), "Corey", "Enter a new setup code."),
            (.failed(message: "The gateway refused this phone."), "Corey", "The gateway refused this phone."),
            (.disconnected, nil, "Pair this phone to get started"),
        ]

        for (state, assistant, line) in cases {
            XCTAssertEqual(state.line(pairedWith: assistant), line, "\(state)")
        }
    }

    /// In place of a title while the link comes back, quietly, and nothing while it is up or
    /// a person has to act, which the banner says.
    func testATitleSaysConnectingOnlyWhileTheLinkComesBack() {
        let cases: [(state: ConnectionState, title: String?)] = [
            (.connected, nil),
            (.connecting, "Connecting\u{2026}"),
            (.reconnecting(attempt: 3), "Connecting\u{2026}"),
            (.disconnected, "Not connected"),
            (.pairingPending(requestId: nil), nil),
            (.needsPairing(message: "Enter a new setup code."), nil),
            (.failed(message: "The gateway refused this phone."), nil),
        ]

        for (state, title) in cases {
            XCTAssertEqual(state.comingBackTitle, title, "\(state)")
        }
    }

    func testRefusalsAreClassifiedByDetailCode() {
        func refusal(_ detail: String) -> GatewayErrorShape {
            GatewayErrorShape(code: "INVALID_REQUEST", message: "m", details: .object(["code": .string(detail)]))
        }
        for detail in ["AUTH_SCOPE_MISMATCH", "AUTH_DEVICE_TOKEN_MISMATCH"] {
            guard case .discardDeviceTokenAndPairAgain = ConnectFailure.classify(refusal(detail)) else {
                return XCTFail(detail)
            }
        }
        for detail in ["AUTH_BOOTSTRAP_TOKEN_INVALID", "AUTH_TOKEN_MISMATCH", "AUTH_TOKEN_MISSING", "AUTH_REQUIRED", "AUTH_UNAUTHORIZED"] {
            guard case .askForNewSetupCode = ConnectFailure.classify(refusal(detail)) else {
                return XCTFail(detail)
            }
        }
        XCTAssertEqual(ConnectFailure.classify(refusal("AUTH_RATE_LIMITED")), .retryLater)
        XCTAssertEqual(ConnectFailure.classify(refusal("SOMETHING_NEW")), .stop(message: "m"))
        guard case .stop = ConnectFailure.classify(refusal("PROTOCOL_MISMATCH")) else {
            return XCTFail("PROTOCOL_MISMATCH")
        }
    }

    func testTheLevelEnvelopeRisesFastAndFallsSlowly() {
        var envelope = LevelEnvelope()
        let risen = envelope.feed(1)
        XCTAssertGreaterThan(risen, 0.5)
        let fallen = envelope.feed(0)
        XCTAssertGreaterThan(fallen, risen * 0.8)
        XCTAssertEqual(envelope.feed(7), envelope.level)
        XCTAssertLessThanOrEqual(envelope.level, 1)
    }

    func testLevelNormalisation() {
        XCTAssertEqual(LevelEnvelope.normalized(rms: 0), 0)
        XCTAssertEqual(LevelEnvelope.normalized(rms: 1), 1)
        XCTAssertEqual(LevelEnvelope.normalized(rms: 0.0001), 0)
        XCTAssertEqual(LevelEnvelope.normalized(rms: 0.1), 0.6, accuracy: 0.001)
    }

    func testMessageTimeSpans() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: -4 * 3600))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 9, minute: 41)))
        let cases: [(hoursBefore: Double, span: MessageTime.Span)] = [
            (0, .today),
            (9, .today),
            (10, .yesterday),
            (33, .yesterday),
            (34, .thisWeek),
            (6 * 24, .thisWeek),
            (7 * 24, .older),
            (400 * 24, .older),
        ]
        for (hoursBefore, span) in cases {
            let date = now.addingTimeInterval(-hoursBefore * 3600)
            XCTAssertEqual(MessageTime.span(of: date, now: now, calendar: calendar), span, "\(hoursBefore) hours before")
        }
        let beforeMidnight = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 23, minute: 59)))
        XCTAssertEqual(MessageTime.span(of: beforeMidnight.addingTimeInterval(2 * 60), now: beforeMidnight, calendar: calendar), .today)
    }

    /// The room sets the day in bold beside the clock, as "Today 6:12 PM".
    func testADividerSaysTheDayBesideTheClock() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: -4 * 3600))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 9, minute: 41)))
        let earlier = now.addingTimeInterval(-3600)
        let today = MessageTime.divider(for: earlier, now: now, calendar: calendar)
        XCTAssertEqual(today.day, "Today")
        XCTAssertEqual(today.time, earlier.formatted(date: .omitted, time: .shortened))
        XCTAssertEqual(MessageTime.divider(for: now.addingTimeInterval(-20 * 3600), now: now, calendar: calendar).day, "Yesterday")
        let lastWeek = MessageTime.divider(for: now.addingTimeInterval(-3 * 24 * 3600), now: now, calendar: calendar)
        XCTAssertFalse(lastWeek.day.isEmpty)
        XCTAssertFalse(lastWeek.day.contains(lastWeek.time), "the day and the clock are apart")
    }
}
