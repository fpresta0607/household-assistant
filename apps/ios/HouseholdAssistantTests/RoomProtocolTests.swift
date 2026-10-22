// The household-app plugin's side of the protocol: what the phone signs, and what the
// gateway sends back.
//
// The household-app fixtures were written by the plugin's own code
// (deploy/openclaw/plugins/household-app) with invented words, so these tests decode
// exactly what that code sends. The signed text is checked against the same vector
// the plugin's own test uses, so a change on either side fails one of the two.

import XCTest
@testable import HouseholdAssistant

final class RoomProtocolTests: XCTestCase {
    func testTheSignedTextIsTheOneThePluginChecks() {
        // tests/js/household_app_signature.test.mjs, "the signed text is one line per field".
        XCTAssertEqual(
            RoomSignature.signedText(
                conversation: .family,
                id: "m-6f1d0c3e-1b2a-4c5d-9e8f-0a1b2c3d4e5f",
                at: 1_792_540_800_000,
                replyTo: nil,
                mediaIds: [],
                text: "Corey, can you add milk to the list?\nAnd eggs."
            ),
            "household-app/v1\nfamily\nm-6f1d0c3e-1b2a-4c5d-9e8f-0a1b2c3d4e5f\n1792540800000\n\n\nCorey, can you add milk to the list?\nAnd eggs."
        )
    }

    func testAttachmentsAndAReplyAreSignedInTheirFields() {
        XCTAssertEqual(
            RoomSignature.signedText(
                conversation: .family,
                id: "m-1",
                at: 5,
                replyTo: "a-2",
                mediaIds: [String(repeating: "a", count: 64), String(repeating: "b", count: 64)],
                text: ""
            ),
            "household-app/v1\nfamily\nm-1\n5\na-2\n\(String(repeating: "a", count: 64)),\(String(repeating: "b", count: 64))\n"
        )
    }

    func testAFieldThatWouldSpanTwoLinesCannotBeSigned() {
        XCTAssertNil(RoomSignature.signedText(conversation: .family, id: "m-1\nfamily", at: 1, replyTo: nil, mediaIds: [], text: "x"))
        XCTAssertNil(RoomSignature.signedText(conversation: .family, id: "m-1", at: 1, replyTo: "a\r", mediaIds: [], text: "x"))
        XCTAssertNil(RoomSignature.signedText(conversation: .family, id: "m-1", at: 1, replyTo: nil, mediaIds: ["a\nb"], text: "x"))
    }

    func testACatchUpPageDecodes() throws {
        let page = try payload("household-app-sync-response").decoded(as: RoomSyncPage.self)
        XCTAssertEqual(page.rev, 6)
        XCTAssertFalse(page.hasMore)
        XCTAssertEqual(page.entries.map(\.kind), [.message, .message, .message, .reaction, .read, .message])
        XCTAssertEqual(page.entries.map(\.rev), [1, 2, 3, 4, 5, 6])

        let franco = page.entries[0]
        XCTAssertEqual(franco.author, "franco")
        XCTAssertEqual(franco.conversation, "family")
        XCTAssertEqual(franco.text, "Corey, can you add milk to the list?")
        XCTAssertEqual(franco.sentAt, Date(timeIntervalSince1970: 1_792_018_799.5))

        XCTAssertEqual(page.entries[1].runId, "run-fixture-1")

        let voice = try XCTUnwrap(page.entries[2].media?.first)
        XCTAssertEqual(voice.kind, .voice)
        XCTAssertEqual(voice.mime, "audio/mp4")
        XCTAssertEqual(voice.durationMs, 4200)
        XCTAssertEqual(voice.waveform, [0.1, 0.4, 0.9, 0.6, 0.2])

        XCTAssertEqual(page.entries[3].messageId, franco.id)
        XCTAssertEqual(page.entries[3].emoji, "❤️")
        XCTAssertEqual(page.entries[4].messageId, franco.id)
        XCTAssertEqual(page.entries[5].conversation, "direct")

        XCTAssertEqual(page.participants.map(\.id), ["franco", "gia", "corey", "denise"])
        XCTAssertEqual(page.participants.map(\.kind), [.person, .person, .assistant, .assistant])
        XCTAssertEqual(page.participants.first { $0.isOwner }?.id, "franco")
        XCTAssertEqual(page.participants.map(\.emoji), [nil, nil, "🦉", "🌸"])
        XCTAssertEqual(page.me, RoomSelf(person: "franco", assistant: "corey"))
        XCTAssertEqual(page.sessionKeys[.family], "agent:main:household:group:family")
        XCTAssertEqual(page.sessionKeys[.direct], "agent:main:household:direct:franco")
    }

    func testAHistoryPageDecodesWithItsReactionsAndReadMarkers() throws {
        let page = try payload("household-app-history-response").decoded(as: RoomHistoryPage.self)
        XCTAssertEqual(page.messages.map(\.author), ["franco", "corey", "gia"])
        XCTAssertFalse(page.hasMore)
        let first = page.messages[0].id
        XCTAssertEqual(page.reactions[first], [RoomReaction(author: "gia", emoji: "❤️")])
        XCTAssertEqual(page.reads, [RoomReadMarker(author: "gia", messageId: first)])
        XCTAssertEqual(page.me, RoomSelf(person: "franco", assistant: "corey"))
    }

    func testThePluginsTwoEventsAreRecognised() throws {
        XCTAssertEqual(try event("household-app-changed-event"), .changed(rev: 6))
        XCTAssertEqual(
            try event("household-app-typing-event"),
            .typing(conversation: .family, author: "denise", isActive: true)
        )
        XCTAssertNil(RoomEvent(GatewayEvent(event: "chat", payload: .object([:]), seq: 1)))
        XCTAssertNil(RoomEvent(GatewayEvent(event: "plugin.household-app.typing", payload: .object(["conversation": .string("telegram")]), seq: 1)))
    }

    /// Shaped as OpenClaw 2026.9.4 sends a channel run's tool step to a connection that
    /// follows the session: `sendAgentPayload` in its server-chat.ts, with the `data` its
    /// embedded runner emits for a tool's start.
    func testAToolStepOfAnAssistantsRunIsRecognised() throws {
        let start = GatewayEvent(event: "agent", payload: .object([
            "runId": .string("run-7"), "stream": .string("tool"), "seq": .number(4), "ts": .number(1_792_050_000_000),
            "sessionKey": .string("agent:main:household:direct:franco"), "agentId": .string("main"),
            "data": .object([
                "phase": .string("start"), "name": .string("exec"), "toolCallId": .string("call-1"),
                "args": .object(["command": .string("gog calendar events --today"), "timeout": .number(30)]),
            ]),
        ]), seq: 12)
        let tool = try XCTUnwrap(AgentToolEvent(start))
        XCTAssertEqual(tool.sessionKey, "agent:main:household:direct:franco")
        XCTAssertEqual(tool.phase, .start)
        XCTAssertEqual(tool.name, "exec")
        XCTAssertEqual(tool.toolCallId, "call-1")
        XCTAssertEqual(tool.command, "gog calendar events --today")

        let result = GatewayEvent(event: "agent", payload: .object([
            "runId": .string("run-7"), "stream": .string("tool"), "seq": .number(5),
            "sessionKey": .string("agent:main:household:direct:franco"),
            "data": .object(["phase": .string("result"), "name": .string("exec"), "toolCallId": .string("call-1"), "isError": .bool(false)]),
        ]), seq: 13)
        XCTAssertEqual(AgentToolEvent(result)?.phase, .result)
        XCTAssertNil(AgentToolEvent(result)?.command)

        guard case .event(let status) = try GatewayCodec.decode(try Fixtures.text("event-agent-ignored")) else {
            return XCTFail("the captured run status is not an event")
        }
        XCTAssertNil(AgentToolEvent(status), "a run's status is not a tool")
        XCTAssertNil(AgentToolEvent(GatewayEvent(event: "chat", payload: start.payload, seq: 1)))
    }

    func testTheRunAToolStepBelongsToIsRead() throws {
        let step = GatewayEvent(event: "agent", payload: .object([
            "runId": .string("run-7"), "stream": .string("tool"), "sessionKey": .string("agent:main:household:direct:franco"),
            "data": .object(["phase": .string("start"), "name": .string("web_search"), "toolCallId": .string("call-2")]),
        ]), seq: 1)
        XCTAssertEqual(AgentToolEvent(step)?.runId, "run-7")
    }

    // MARK: - Approvals

    func testTheSignedAnswerIsTheOneThePluginChecks() {
        // tests/js/household_app_approvals.test.mjs, "the signed answer is one line per field".
        XCTAssertEqual(ApprovalAnswer.signedText(approvalId: "plugin:abc", decision: .deny), "household-app/approval/v1\nplugin:abc\ndeny")
        XCTAssertEqual(
            ApprovalAnswer.signedText(approvalId: "0d6b7c1a-2f4e-4b8a-a1c3-5e9f7d2b4a60", decision: .approve),
            "household-app/approval/v1\n0d6b7c1a-2f4e-4b8a-a1c3-5e9f7d2b4a60\nallow-once"
        )
        XCTAssertNil(ApprovalAnswer.signedText(approvalId: "plugin:abc\nallow-once", decision: .deny))
        XCTAssertNil(ApprovalAnswer.signedText(approvalId: "", decision: .deny))
    }

    /// Shaped as deploy/openclaw/plugins/household-app/approvals.js keeps an approval card.
    func testAnApprovalCardIsAMessageThatCarriesItsApproval() throws {
        let entry = try JSONValue.object([
            "id": .string("ap-d91befb6b8489244c6be2229f11abef111b0b8eb"), "rev": .number(12), "kind": .string("message"),
            "conversation": .string("direct"), "author": .string("corey"), "at": .number(1_792_540_800_000),
            "origin": .string("local"), "text": .string("Needs your OK: Add to the family calendar"), "media": .array([]),
            "replyTo": .null,
            "approval": .object([
                "id": .string("plugin:5f0c1d9e"), "kind": .string("plugin"), "title": .string("Add to the family calendar"),
                "detail": .string("Soccer pickup, Saturday 5:45 to 6:15 PM"),
                "decisions": .array([.string("allow-once"), .string("allow-always"), .string("deny")]),
            ]),
        ]).decoded(as: RoomEntry.self)

        XCTAssertEqual(entry.kind, .message)
        XCTAssertEqual(entry.approval?.id, "plugin:5f0c1d9e")
        XCTAssertEqual(entry.approval?.title, "Add to the family calendar")
        XCTAssertEqual(entry.approval?.detail, "Soccer pickup, Saturday 5:45 to 6:15 PM")
        XCTAssertEqual(entry.approval?.decisions, [.approve, .deny], "an answer this version cannot give is not offered")
        XCTAssertEqual(entry.approval?.isCommand, false)
        XCTAssertEqual(RoomMessage(entry).approval, entry.approval)

        let command = try JSONValue.object([
            "id": .string("0d6b7c1a"), "kind": .string("exec"), "title": .string("Run a command"),
            "detail": .string("gog calendar add"), "decisions": .array([.string("allow-once"), .string("deny")]),
        ]).decoded(as: RoomApproval.self)
        XCTAssertTrue(command.isCommand)
    }

    func testAnApprovalTheGatewayDescribesBadlyIsAnOrdinaryMessage() throws {
        let entry = try JSONValue.object([
            "id": .string("ap-1"), "rev": .number(12), "kind": .string("message"), "conversation": .string("direct"),
            "author": .string("corey"), "at": .number(1), "origin": .string("local"), "text": .string("Needs your OK"),
            "media": .array([]), "approval": .object(["title": .number(4)]),
        ]).decoded(as: RoomEntry.self)
        XCTAssertNil(entry.approval)
        XCTAssertEqual(entry.text, "Needs your OK")
    }

    func testHowAnApprovalEndedIsAnEntryAboutItsCard() throws {
        let ended = try JSONValue.object([
            "id": .string("approval:ap-1"), "rev": .number(13), "kind": .string("approval"), "conversation": .string("direct"),
            "author": .string("corey"), "at": .number(1), "origin": .string("local"), "target": .string("ap-1"),
            "messageId": .string("ap-1"), "state": .string("denied"),
        ]).decoded(as: RoomEntry.self)
        XCTAssertEqual(ended.kind, .approval)
        XCTAssertEqual(ended.messageId, "ap-1")
        XCTAssertEqual(ended.approvalOutcome, .denied)

        let later = try JSONValue.object([
            "id": .string("approval:ap-2"), "rev": .number(14), "kind": .string("approval"), "conversation": .string("direct"),
            "author": .string("corey"), "at": .number(1), "origin": .string("local"), "messageId": .string("ap-2"),
            "state": .string("withdrawn"),
        ]).decoded(as: RoomEntry.self)
        XCTAssertNil(later.approvalOutcome, "an end a later gateway adds is not guessed at")
    }

    func testAHistoryPageSaysHowItsApprovalsEnded() throws {
        var page = try payload("household-app-history-response")
        XCTAssertNil(try page.decoded(as: RoomHistoryPage.self).approvals, "a gateway from before approvals sends none")
        if case .object(var members) = page {
            members["approvals"] = .object(["ap-1": .string("approved")])
            page = .object(members)
        }
        XCTAssertEqual(try page.decoded(as: RoomHistoryPage.self).approvals, ["ap-1": "approved"])
    }

    func testAnEntryOfAKindThisVersionDoesNotKnowIsKeptAsUnknown() throws {
        let entry = try JSONValue.object([
            "id": .string("poll:1"), "rev": .number(9), "kind": .string("poll"), "conversation": .string("family"),
            "author": .string("gia"), "at": .number(1), "origin": .string("peer"),
        ]).decoded(as: RoomEntry.self)
        XCTAssertEqual(entry.kind, .unknown)
    }

    func testAnAttachmentOfAKindThisVersionDoesNotKnowReadsAsAFile() throws {
        let media = try JSONValue.object([
            "id": .string(String(repeating: "a", count: 64)), "kind": .string("sticker"),
            "mime": .string("image/webp"), "bytes": .number(10),
        ]).decoded(as: RoomMedia.self)
        XCTAssertEqual(media.kind, .file)
    }

    func testAnOutgoingMessageSaysExactlyWhatWasSigned() throws {
        var signed: [String] = []
        let outgoing = try RoomOutgoing(conversation: .family, id: "m-1", at: 7, replyTo: nil, media: [], text: "hello") { text in
            signed.append(text)
            return "c2ln"
        }
        XCTAssertEqual(signed, ["household-app/v1\nfamily\nm-1\n7\n\n\nhello"])
        XCTAssertEqual(outgoing.params["signature"]?.stringValue, "c2ln")
        XCTAssertEqual(outgoing.params["at"]?.intValue, 7)
        XCTAssertEqual(outgoing.params["replyTo"], .null)
        XCTAssertEqual(outgoing.params["conversation"]?.stringValue, "family")
    }

    func testADirectMessageIsSignedOverItsOwnConversation() throws {
        var signed: [String] = []
        let outgoing = try RoomOutgoing(conversation: .direct, id: "d-1", at: 7, replyTo: "a-1", media: [], text: "What is on today?") { text in
            signed.append(text)
            return "c2ln"
        }
        XCTAssertEqual(signed, ["household-app/v1\ndirect\nd-1\n7\na-1\n\nWhat is on today?"])
        XCTAssertEqual(outgoing.params["signature"]?.stringValue, "c2ln")
    }

    /// Words said on a call are marked beside what is signed, never in it, so the mark only
    /// shapes the gateway's instructions for that turn.
    func testWordsSaidOnACallAreMarkedBesideWhatIsSigned() throws {
        // Arrange
        var signed: [String] = []
        let sign: (String) throws -> String = { text in
            signed.append(text)
            return "c2ln"
        }

        // Act
        let spoken = try RoomOutgoing(conversation: .direct, id: "d-1", at: 7, replyTo: nil, media: [], text: "Is it cold inside?", isCall: true, sign: sign)
        let typed = try RoomOutgoing(conversation: .direct, id: "d-1", at: 7, replyTo: nil, media: [], text: "Is it cold inside?", sign: sign)

        // Assert
        XCTAssertEqual(signed, Array(repeating: "household-app/v1\ndirect\nd-1\n7\n\n\nIs it cold inside?", count: 2))
        XCTAssertEqual(spoken.params["call"], .bool(true))
        XCTAssertNil(typed.params["call"], "typed words carry no mark")
    }

    func testAMessageWhoseFieldsCannotBeSignedIsNeverSent() {
        XCTAssertThrowsError(try RoomOutgoing(conversation: .direct, id: "d-1\nfamily", at: 7, replyTo: nil, media: [], text: "hi") { _ in
            XCTFail("signed a message whose id spans two lines")
            return "c2ln"
        })
    }

    private func payload(_ name: String) throws -> JSONValue {
        guard case .response(let response) = try GatewayCodec.decode(try Fixtures.text(name)) else {
            throw XCTSkip("not a response")
        }
        return try XCTUnwrap(response.payload)
    }

    private func event(_ name: String) throws -> RoomEvent? {
        guard case .event(let event) = try GatewayCodec.decode(try Fixtures.text(name)) else {
            throw XCTSkip("not an event")
        }
        return RoomEvent(event)
    }
}
