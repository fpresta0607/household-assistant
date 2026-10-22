// A call with the assistant as its thread keeps it once it ended: one call entry with the
// words alone, standing in for the messages the call's words were said in.

import XCTest
@testable import HouseholdAssistant

final class CallLogTests: XCTestCase {
    private static let started = 1_792_018_800_000

    private func entry(_ id: String, rev: Int, author: String = "franco", text: String = "hello", at: Int = started + 1_000) throws -> RoomEntry {
        try JSONValue.object([
            "id": .string(id), "rev": .number(Double(rev)), "kind": .string("message"),
            "conversation": .string("direct"), "author": .string(author), "at": .number(Double(at)),
            "origin": .string("local"), "text": .string(text), "media": .array([]),
        ]).decoded(as: RoomEntry.self)
    }

    private func call(rev: Int, turnIds: [String], endedAt: Int = started + 247_000, isCut: Bool = false) throws -> RoomEntry {
        try JSONValue.object([
            "id": .string("call:0b6f3c1e-8f0a-4c55-9a59-2f7d4c1b9e10"), "rev": .number(Double(rev)),
            "kind": .string("call"), "conversation": .string("direct"), "author": .string("franco"),
            "at": .number(Double(Self.started)), "endedAt": .number(Double(endedAt)), "with": .string("corey"),
            "turnIds": .array(turnIds.map(JSONValue.string)),
            "transcript": .array([
                .object(["author": .string("franco"), "text": .string("What's on today?"), "at": .number(Double(Self.started + 1_000))]),
                .object(["author": .string("corey"), "text": .string("Dentist at 3:30."), "at": .number(Double(Self.started + 4_000))]),
                .object(["author": .string("corey"), "words": .string("a line a later gateway shapes otherwise")]),
            ]),
            "isCut": .bool(isCut), "origin": .string("local"),
        ]).decoded(as: RoomEntry.self)
    }

    func testACallEntryDecodesWithItsWordsAndWhoItWasWith() throws {
        // Act
        let decoded = try call(rev: 9, turnIds: ["d-1", "a-1"], isCut: true)
        let shown = try XCTUnwrap(RoomCall(decoded))

        // Assert
        XCTAssertEqual(decoded.kind, .call)
        XCTAssertEqual(shown.assistant, "corey")
        XCTAssertEqual(shown.turnIds, ["d-1", "a-1"])
        XCTAssertEqual(shown.transcript.map(\.text), ["What's on today?", "Dentist at 3:30."], "a line this version cannot read is left out")
        XCTAssertTrue(shown.isCut)
        XCTAssertEqual(shown.seconds, 247)
    }

    func testAnEndedCallStandsInForTheMessagesItsWordsWereSaidIn() throws {
        // Arrange
        var thread = RoomThread(.direct)
        thread.apply(try entry("d-0", rev: 1, text: "Before the call"))
        thread.apply(try entry("d-1", rev: 2, text: "What's on today?"))
        thread.apply(try entry("a-1", rev: 3, author: "corey", text: "Dentist at 3:30."))

        // Act
        thread.apply(try call(rev: 4, turnIds: ["d-1", "a-1"]))

        // Assert
        XCTAssertEqual(thread.messages.map(\.id), ["d-0", "call:0b6f3c1e-8f0a-4c55-9a59-2f7d4c1b9e10"])
        XCTAssertNotNil(thread.messages.last?.call)
    }

    func testAFoldedMessageThatArrivesAfterItsCallStaysOut() throws {
        // Arrange
        var thread = RoomThread(.direct)
        thread.apply(try call(rev: 4, turnIds: ["d-1", "a-1"]))

        // Act
        thread.apply(try entry("a-1", rev: 3, author: "corey", text: "Dentist at 3:30."))
        thread.apply(try call(rev: 4, turnIds: ["d-1", "a-1"]))

        // Assert
        XCTAssertEqual(thread.messages.map(\.id), ["call:0b6f3c1e-8f0a-4c55-9a59-2f7d4c1b9e10"])
    }

    func testACallsLengthReadsAsThePhoneAppSaysIt() throws {
        // Arrange
        let short = try XCTUnwrap(RoomCall(try call(rev: 1, turnIds: [], endedAt: Self.started + 247_000)))
        let long = try XCTUnwrap(RoomCall(try call(rev: 1, turnIds: [], endedAt: Self.started + 3_729_000)))
        let none = try XCTUnwrap(RoomCall(try call(rev: 1, turnIds: [], endedAt: Self.started)))

        // Assert
        XCTAssertEqual(short.length, "4:07")
        XCTAssertEqual(long.length, "1:02:09")
        XCTAssertEqual(none.length, "0:00")
    }

    func testACallFoldsEachKeptTurnAndItsKeptReplyOnly() throws {
        // Arrange
        var thread = RoomThread(.direct)
        thread.apply(try entry("d-0", rev: 1, text: "Before the call"))
        thread.apply(try entry("d-1", rev: 2, text: "What's on today?"))
        thread.apply(try entry("a-1", rev: 3, author: "corey", text: "Dentist at 3:30."))
        thread.apply(try entry("d-2", rev: 4, text: "And tomorrow?"))
        thread.stream(runId: "run-2", author: "corey", text: "Tomorrow is", replace: true)
        thread.addPending(RoomMessage(id: "d-3", author: "franco", text: "Never kept", media: [], replyTo: nil, sentAt: Date(), status: .sending))

        // Act
        let turns = RoomCall.turnIds(asked: ["d-1", "d-2", "d-3"], in: thread, assistant: "corey")

        // Assert
        XCTAssertEqual(turns, ["d-1", "a-1", "d-2"], "the reply still arriving and the turn never kept stay messages")
    }

    func testTheCallsEndSignsTheCallItsTimesAndItsMessagesAsThePluginChecks() {
        // Act
        let text = RoomSignature.callEndText(callId: "c-1", startedAt: 1_792_018_800_000, endedAt: 1_792_019_047_000, turns: ["d-1", "a-1"])

        // Assert
        XCTAssertEqual(text, "household-app/call/v1\nc-1\n1792018800000\n1792019047000\nd-1,a-1")
    }

    func testACallWithNoWordsIsSignedWithAnEmptyLastLine() {
        XCTAssertEqual(
            RoomSignature.callEndText(callId: "c-1", startedAt: 1, endedAt: 2, turns: []),
            "household-app/call/v1\nc-1\n1\n2\n"
        )
    }

    func testAnIdThatWouldBreakTheSignedTextCannotBeSigned() {
        XCTAssertNil(RoomSignature.callEndText(callId: "c-1", startedAt: 1, endedAt: 2, turns: ["d-1,a-1"]))
        XCTAssertNil(RoomSignature.callEndText(callId: "c-1\nx", startedAt: 1, endedAt: 2, turns: []))
    }
}
