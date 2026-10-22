// The rows a thread's list shows: one per message by its bubble, the receipt under this
// phone's newest message from the moment it is sent, who is typing until their reply is
// complete and ready to draw, which shows whole, with what this phone's assistant is doing
// in either conversation and no line of its steps, and the rows a message lifted for
// reactions and a late word of a kept reply make.

import XCTest
@testable import HouseholdAssistant

final class ThreadRowTests: XCTestCase {
    private static let me = RoomSelf(person: "franco", assistant: "corey")

    private func entry(
        _ id: String,
        rev: Int,
        conversation: String = "direct",
        author: String = "franco",
        text: String = "hello",
        runId: String? = nil
    ) throws -> RoomEntry {
        var members: [String: JSONValue] = [
            "id": .string(id), "rev": .number(Double(rev)), "kind": .string("message"),
            "conversation": .string(conversation), "author": .string(author),
            "at": .number(1_792_018_800_000 + Double(rev) * 60_000), "origin": .string("local"),
            "text": .string(text), "media": .array([]),
        ]
        if let runId {
            members["runId"] = .string(runId)
        }
        return try JSONValue.object(members).decoded(as: RoomEntry.self)
    }

    private func rows(
        of thread: RoomThread,
        typing: [String] = [],
        activity: AssistantActivity? = nil,
        readying: Set<String> = [],
        shared: [ShareHandoff] = [],
        isConnected: Bool = true,
        lifted: String? = nil
    ) -> [ThreadRow] {
        ThreadRow.rows(
            of: thread,
            me: Self.me,
            assistants: ["corey"],
            typing: typing,
            activity: activity,
            readying: readying,
            shared: shared,
            isConnected: isConnected,
            lifted: lifted
        )
    }

    private func messageRow(_ row: ThreadRow) -> ThreadRow.Message? {
        if case .message(let message) = row.content {
            return message
        }
        return nil
    }

    func testEachMessageIsARowByTheBubbleItShowsIn() throws {
        var thread = RoomThread(.direct)
        thread.apply(try entry("d-1", rev: 1))
        thread.stream(runId: "run-1", author: "corey", text: "Pasta", replace: false)
        thread.apply(try entry("a-1", rev: 2, author: "corey", text: "Pasta tonight.", runId: "run-1"))

        let ids = rows(of: thread).map(\.id)

        XCTAssertEqual(ids, [.message(bubble: "d-1", occurrence: 0), .message(bubble: "run:run-1", occurrence: 0)])
    }

    func testALateWordOfAKeptReplyIsARowOfItsOwnOnceItEnds() throws {
        var thread = RoomThread(.direct)
        thread.stream(runId: "run-1", author: "corey", text: "Pasta", replace: false)
        thread.apply(try entry("a-1", rev: 1, author: "corey", text: "Pasta tonight.", runId: "run-1"))
        thread.stream(runId: "run-1", author: "corey", text: ".", replace: false)
        thread.endStream(runId: "run-1", failure: nil)

        let ids = rows(of: thread).map(\.id)

        XCTAssertEqual(ids, [.message(bubble: "run:run-1", occurrence: 0), .message(bubble: "run:run-1", occurrence: 1)])
        XCTAssertEqual(Set(ids).count, ids.count, "the list cannot hold one id twice")
    }

    func testAWordStreamingIntoAReplyChangesNoRow() throws {
        var thread = RoomThread(.direct)
        thread.apply(try entry("d-1", rev: 1, text: "What's for dinner?"))
        thread.stream(runId: "run-1", author: "corey", text: "Pasta", replace: false)
        let before = rows(of: thread, typing: ["corey"])
        thread.stream(runId: "run-1", author: "corey", text: " tonight.", replace: false)

        let after = rows(of: thread, typing: ["corey"])

        XCTAssertEqual(after, before)
        XCTAssertEqual(after.map(\.id), [.message(bubble: "d-1", occurrence: 0), .typing("corey")])
    }

    func testTheReceiptGoesUnderThisPhonesNewestMessageFromTheMomentItIsSent() throws {
        var thread = RoomThread(.direct)
        thread.apply(try entry("d-1", rev: 1))
        thread.apply(try entry("d-2", rev: 2))
        thread.apply(try entry("a-1", rev: 3, author: "corey"))
        thread.addPending(RoomMessage(id: "d-3", author: "franco", text: "on my way", media: [], replyTo: nil, sentAt: Date(), status: .sending))

        let readers = rows(of: thread).map { messageRow($0)?.readers }

        XCTAssertEqual(readers, [nil, nil, nil, []], "d-3 keeps the receipt's room while the gateway keeps it")
    }

    func testAMessageWaitingOrRefusedLeavesTheReceiptUnderTheNewestKept() throws {
        for status in [RoomMessage.Status.waiting, .failed("refused")] {
            var thread = RoomThread(.direct)
            thread.apply(try entry("d-1", rev: 1))
            thread.addPending(RoomMessage(id: "d-2", author: "franco", text: "on my way", media: [], replyTo: nil, sentAt: Date(), status: status))

            let readers = rows(of: thread).map { messageRow($0)?.readers }

            XCTAssertEqual(readers, [[], nil], "\(status)")
        }
    }

    func testSomeoneTypingStandsInForTheirReplyUntilItIsComplete() throws {
        var thread = RoomThread(.direct)
        thread.apply(try entry("d-1", rev: 1))
        XCTAssertEqual(rows(of: thread, typing: ["corey"]).last?.id, .typing("corey"))

        thread.stream(runId: "run-1", author: "corey", text: "On it", replace: false)
        XCTAssertEqual(rows(of: thread).map(\.id), [.message(bubble: "d-1", occurrence: 0), .typing("corey")], "not one word before it is complete")

        thread.endStream(runId: "run-1", failure: nil)
        XCTAssertEqual(
            rows(of: thread, typing: ["corey"]).map(\.id),
            [.message(bubble: "d-1", occurrence: 0), .message(bubble: "run:run-1", occurrence: 0)],
            "the whole reply in the typing row's place, though the gateway still says typing until it keeps it"
        )
    }

    func testAnAssistantTypingAgainAfterItsOwnMessageShowsTheDots() throws {
        // Arrange
        var thread = RoomThread(.direct)
        thread.apply(try entry("d-1", rev: 1))
        thread.apply(try entry("a-1", rev: 2, author: "corey", text: "Here it is."))

        // Act
        let shown = rows(of: thread, typing: ["corey"])

        // Assert
        XCTAssertEqual(shown.last?.id, .typing("corey"), "a second message from Corey is on its way")
    }

    func testAFinishedReplyWaitsWhileItsWordsAreMadeReadyToDraw() throws {
        var thread = RoomThread(.direct)
        thread.apply(try entry("d-1", rev: 1))
        thread.stream(runId: "run-1", author: "corey", text: "On it", replace: false)
        thread.endStream(runId: "run-1", failure: nil)

        let waiting = rows(of: thread, typing: ["corey"], readying: ["run:run-1"]).map(\.id)
        let ready = rows(of: thread, typing: ["corey"]).map(\.id)

        XCTAssertEqual(waiting, [.message(bubble: "d-1", occurrence: 0), .typing("corey")])
        XCTAssertEqual(ready, [.message(bubble: "d-1", occurrence: 0), .message(bubble: "run:run-1", occurrence: 0)])
    }

    func testAReplyThatBrokeOffShowsWithWhatItSaid() throws {
        var thread = RoomThread(.direct)
        thread.apply(try entry("d-1", rev: 1))
        thread.stream(runId: "run-1", author: "corey", text: "Let me", replace: false)
        thread.endStream(runId: "run-1", failure: "The assistant could not finish that reply.")

        let shown = rows(of: thread, typing: ["corey"])

        XCTAssertEqual(shown.map(\.id), [.message(bubble: "d-1", occurrence: 0), .message(bubble: "run:run-1", occurrence: 0)])
        XCTAssertEqual(shown.last.flatMap(messageRow)?.message.status, .failed("The assistant could not finish that reply."))
    }

    func testTheTypingBubbleSaysWhatTheAssistantIsDoingInItsOwnThreadWhileItsReplyStreams() throws {
        var thread = RoomThread(.direct)
        thread.apply(try entry("d-1", rev: 1, text: "What's on tomorrow?"))
        thread.stream(runId: "run-1", author: "corey", text: "Let me look.", replace: false)

        let shown = rows(of: thread, typing: ["corey"], activity: .calendar)

        XCTAssertEqual(shown.map(\.id), [
            .message(bubble: "d-1", occurrence: 0),
            .typing("corey"),
        ], "no line of its steps shows before or around the reply")
        XCTAssertEqual(shown.last?.content, .typing(ThreadRow.Typing(participant: "corey", activity: .calendar)))
    }

    func testOnlyThisPhonesAssistantSaysWhatItIsDoing() throws {
        var thread = RoomThread(.family)
        thread.apply(try entry("m-1", rev: 1, conversation: "family"))

        let shown = rows(of: thread, typing: ["corey", "denise"], activity: .webSearch)

        XCTAssertEqual(shown.suffix(2).map(\.content), [
            .typing(ThreadRow.Typing(participant: "corey", activity: .webSearch)),
            .typing(ThreadRow.Typing(participant: "denise", activity: nil)),
        ])
    }

    func testTheHelloShowsInAnEmptyThreadOnceConnected() {
        let thread = RoomThread(.direct)

        XCTAssertEqual(rows(of: thread).map(\.id), [.hello])
        XCTAssertEqual(rows(of: thread, isConnected: false).map(\.id), [])
    }

    func testTheSpinnerShowsAboveWhileOlderMessagesWait() throws {
        let page: JSONValue = .object([
            "messages": .array([]),
            "hasMore": .bool(true),
            "reactions": .object([:]),
            "reads": .array([]),
            "participants": .array([]),
            "self": .object(["person": .string("franco"), "assistant": .string("corey")]),
            "sessionKeys": .object([:]),
        ])
        var thread = RoomThread(.direct)
        thread.load(try page.decoded(as: RoomHistoryPage.self))
        thread.apply(try entry("d-9", rev: 9))

        XCTAssertEqual(rows(of: thread).first?.id, .older)
    }

    func testALiftedMessagesRowSaysSoAndTheRestDoNot() throws {
        var thread = RoomThread(.direct)
        thread.apply(try entry("d-1", rev: 1))
        thread.apply(try entry("d-2", rev: 2))

        let lifted = rows(of: thread, lifted: "d-2").map { messageRow($0)?.isLifted }

        XCTAssertEqual(lifted, [false, true])
    }

    func testWhatIsSharedFromAnotherAppComesLast() throws {
        var thread = RoomThread(.direct)
        thread.apply(try entry("d-1", rev: 1))
        let handoff = ShareHandoff(id: "h-1", conversation: .direct, text: "Look", items: [], at: Date())

        let last = rows(of: thread, typing: ["corey"], shared: [handoff]).suffix(2).map(\.id)

        XCTAssertEqual(last, [.typing("corey"), .shared("h-1")])
    }
}
