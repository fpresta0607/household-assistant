// One conversation on the household-app channel, as the screen shows it: built from
// the gateway's entries, with this phone's own sends shown the moment they are made.

import XCTest
@testable import HouseholdAssistant

final class RoomThreadTests: XCTestCase {
    private func entry(
        _ id: String,
        rev: Int,
        kind: String = "message",
        conversation: String = "family",
        author: String = "franco",
        at: Int = 1_792_018_800_000,
        text: String? = "hello",
        extra: [String: JSONValue] = [:]
    ) throws -> RoomEntry {
        var members: [String: JSONValue] = [
            "id": .string(id), "rev": .number(Double(rev)), "kind": .string(kind),
            "conversation": .string(conversation), "author": .string(author),
            "at": .number(Double(at)), "origin": .string("local"),
        ]
        if let text {
            members["text"] = .string(text)
            members["media"] = .array([])
        }
        for (key, value) in extra {
            members[key] = value
        }
        return try JSONValue.object(members).decoded(as: RoomEntry.self)
    }

    private func pending(_ id: String, text: String = "on my way") -> RoomMessage {
        RoomMessage(id: id, author: "franco", text: text, media: [], replyTo: nil, sentAt: Date(timeIntervalSince1970: 1_792_018_900), status: .sending)
    }

    func testAHistoryPageBecomesTheThreadWithItsReactionsAndReadMarkers() throws {
        let page = try fixture("household-app-history-response").decoded(as: RoomHistoryPage.self)
        var thread = RoomThread(.family)
        thread.load(page)
        XCTAssertEqual(thread.messages.map(\.author), ["franco", "corey", "gia"])
        XCTAssertTrue(thread.messages.allSatisfy { $0.status == .sent })
        XCTAssertEqual(thread.messages[0].reactions, [RoomReaction(author: "gia", emoji: "❤️")])
        XCTAssertEqual(thread.readers(of: thread.messages[0].id), ["gia"])
        XCTAssertEqual(thread.messages[2].media.first?.kind, .voice)
        XCTAssertFalse(thread.hasOlder)
    }

    func testNewMessagesArriveInRevisionOrderAndARepeatChangesNothing() throws {
        var thread = RoomThread(.family)
        thread.apply(try entry("m-2", rev: 2))
        thread.apply(try entry("m-1", rev: 1))
        thread.apply(try entry("m-2", rev: 2, text: "changed"))
        XCTAssertEqual(thread.messages.map(\.id), ["m-1", "m-2"])
        XCTAssertEqual(thread.messages[1].text, "hello")
    }

    func testTheOtherConversationsEntriesAreNotThisThreads() throws {
        var thread = RoomThread(.family)
        thread.apply(try entry("d-1", rev: 1, conversation: "direct"))
        XCTAssertTrue(thread.messages.isEmpty)
    }

    func testAReactionIsShownReplacedAndTakenBack() throws {
        var thread = RoomThread(.family)
        thread.apply(try entry("m-1", rev: 1))
        thread.apply(try entry("reaction:m-1:gia", rev: 2, kind: "reaction", author: "gia", text: nil,
                                extra: ["messageId": .string("m-1"), "emoji": .string("👍")]))
        XCTAssertEqual(thread.messages[0].reactions, [RoomReaction(author: "gia", emoji: "👍")])
        thread.apply(try entry("reaction:m-1:gia", rev: 3, kind: "reaction", author: "gia", text: nil,
                                extra: ["messageId": .string("m-1"), "emoji": .string("😂")]))
        XCTAssertEqual(thread.messages[0].reactions, [RoomReaction(author: "gia", emoji: "😂")])
        thread.apply(try entry("reaction:m-1:gia", rev: 4, kind: "reaction", author: "gia", text: nil,
                                extra: ["messageId": .string("m-1"), "emoji": .null]))
        XCTAssertEqual(thread.messages[0].reactions, [])
    }

    func testAReadMarkerSaysWhoHasReadUpToAMessage() throws {
        var thread = RoomThread(.family)
        thread.apply(try entry("m-1", rev: 1))
        thread.apply(try entry("m-2", rev: 2))
        thread.apply(try entry("read:family:gia", rev: 3, kind: "read", author: "gia", text: nil,
                                extra: ["messageId": .string("m-2")]))
        XCTAssertEqual(thread.readers(of: "m-1"), ["gia"])
        XCTAssertEqual(thread.readers(of: "m-2"), ["gia"])
        thread.apply(try entry("m-3", rev: 4))
        XCTAssertEqual(thread.readers(of: "m-3"), [])
    }

    func testThisPhonesSendShowsAtOnceAndSettlesWhenTheGatewayKeepsIt() throws {
        var thread = RoomThread(.family)
        thread.apply(try entry("m-1", rev: 1))
        thread.addPending(pending("m-9"))
        XCTAssertEqual(thread.messages.map(\.id), ["m-1", "m-9"])
        XCTAssertEqual(thread.messages[1].status, .sending)

        thread.apply(try entry("m-2", rev: 2, author: "gia"))
        XCTAssertEqual(thread.messages.map(\.id), ["m-1", "m-2", "m-9"], "a send still in flight stays last")

        thread.apply(try entry("m-9", rev: 3, text: "on my way"))
        XCTAssertEqual(thread.messages.map(\.id), ["m-1", "m-2", "m-9"])
        XCTAssertEqual(thread.messages[2].status, .sent)
        XCTAssertEqual(thread.messages[2].rev, 3)
    }

    func testAFailedSendKeepsItsBubbleAndSaysWhy() {
        var thread = RoomThread(.family)
        thread.addPending(pending("m-9"))
        thread.fail(id: "m-9", reason: "No connection")
        XCTAssertEqual(thread.messages[0].status, .failed("No connection"))
        thread.retrying(id: "m-9")
        XCTAssertEqual(thread.messages[0].status, .sending)
    }

    func testAStreamedReplyGrowsInPlaceAndGivesWayToTheKeptOne() throws {
        var thread = RoomThread(.family)
        thread.apply(try entry("m-1", rev: 1, text: "Corey, what is for dinner?"))
        thread.stream(runId: "run-1", author: "corey", text: "Pasta", replace: false)
        thread.stream(runId: "run-1", author: "corey", text: " tonight.", replace: false)
        XCTAssertEqual(thread.messages.last?.text, "Pasta tonight.")
        XCTAssertEqual(thread.messages.last?.status, .streaming)
        XCTAssertEqual(thread.messages.last?.author, "corey")

        thread.apply(try entry("a-1", rev: 2, author: "corey", text: "Pasta tonight.", extra: ["runId": .string("run-1")]))
        XCTAssertEqual(thread.messages.map(\.id), ["m-1", "a-1"])
        XCTAssertEqual(thread.messages.last?.status, .sent)
    }

    func testAKeptReplyWithNoRunGivesWayToThatAssistantsStreamedOne() throws {
        var thread = RoomThread(.family)
        thread.stream(runId: "run-1", author: "corey", text: "Pasta tonight.", replace: false)
        thread.stream(runId: "run-2", author: "denise", text: "Salad", replace: false)
        thread.apply(try entry("a-1", rev: 1, author: "corey", text: "Pasta tonight."))
        XCTAssertEqual(thread.messages.map(\.id), ["a-1", "run:run-2"])
    }

    func testAKeptReplyStaysInTheBubbleItStreamedIn() throws {
        var thread = RoomThread(.direct)
        thread.stream(runId: "run-1", author: "corey", text: "Pasta", replace: false)
        thread.apply(try entry("a-1", rev: 1, conversation: "direct", author: "corey", text: "Pasta tonight.", extra: ["runId": .string("run-1")]))
        XCTAssertEqual(thread.messages.map(\.id), ["a-1"])
        XCTAssertEqual(thread.messages.map(\.bubbleId), ["run:run-1"])
    }

    func testAKeptReplyWithNoRunStaysInItsAssistantsStreamedBubble() throws {
        var thread = RoomThread(.family)
        thread.stream(runId: "run-1", author: "corey", text: "Pasta tonight.", replace: false)
        thread.stream(runId: "run-2", author: "denise", text: "Salad", replace: false)
        thread.apply(try entry("a-1", rev: 1, author: "corey", text: "Pasta tonight."))
        XCTAssertEqual(thread.messages.map(\.bubbleId), ["run:run-1", "run:run-2"])
    }

    func testAMessageThatNeverStreamedIsABubbleOfItsOwn() throws {
        var thread = RoomThread(.family)
        thread.addPending(pending("m-1"))
        thread.apply(try entry("m-1", rev: 1))
        thread.apply(try entry("m-2", rev: 2, author: "gia"))
        XCTAssertEqual(thread.messages.map(\.bubbleId), ["m-1", "m-2"])
    }

    func testTheLatestPageKeepsTheBubbleAReplyStreamedIn() throws {
        var thread = RoomThread(.direct)
        thread.stream(runId: "run-1", author: "corey", text: "Standup at 9.", replace: false)
        let kept = try entry("a-1", rev: 1, conversation: "direct", author: "corey", text: "Standup at 9.", extra: ["runId": .string("run-1")])
        thread.apply(kept)
        let page = try JSONValue.object([
            "messages": .array([try json(kept), try json(entry("a-2", rev: 2, conversation: "direct", author: "corey"))]),
            "hasMore": .bool(false),
            "reactions": .object([:]),
            "reads": .array([]),
            "participants": .array([]),
            "self": .object(["person": .string("franco"), "assistant": .string("corey")]),
            "sessionKeys": .object([:]),
        ]).decoded(as: RoomHistoryPage.self)
        thread.load(page)
        XCTAssertEqual(thread.messages.map(\.id), ["a-1", "a-2"])
        XCTAssertEqual(thread.messages.map(\.bubbleId), ["run:run-1", "a-2"])
    }

    func testTheReplyToAMessageIsTheAssistantsNextOneWhetherStreamingOrKept() throws {
        var thread = RoomThread(.direct)
        thread.apply(try entry("a-1", rev: 1, conversation: "direct", author: "corey", text: "Earlier answer"))
        thread.apply(try entry("d-2", rev: 2, conversation: "direct", text: "What's on tomorrow?"))
        XCTAssertNil(thread.reply(to: "d-2", from: "corey"), "an answer from before the question is not its reply")

        thread.stream(runId: "run-3", author: "corey", text: "Standup at 9.", replace: false)
        XCTAssertEqual(thread.reply(to: "d-2", from: "corey")?.id, "run:run-3")
        XCTAssertEqual(thread.reply(to: "d-2", from: "corey")?.status, .streaming)

        thread.apply(try entry("a-3", rev: 3, conversation: "direct", author: "corey", text: "Standup at 9.", extra: ["runId": .string("run-3")]))
        XCTAssertEqual(thread.reply(to: "d-2", from: "corey")?.id, "a-3")
        XCTAssertNil(thread.reply(to: "d-9", from: "corey"), "a message the thread does not have has no reply")
    }

    func testAStreamedReplacementReplacesTheTextSoFar() {
        var thread = RoomThread(.direct)
        thread.stream(runId: "run-1", author: "corey", text: "Draft", replace: false)
        thread.stream(runId: "run-1", author: "corey", text: "Final answer", replace: true)
        XCTAssertEqual(thread.messages.last?.text, "Final answer")
    }

    func testAssistantReactionAndWrittenReplyRemainTogetherAfterHistoryReload() throws {
        for conversation in [RoomConversation.direct, .family] {
            let question = try entry("question", rev: 1, conversation: conversation.rawValue)
            let reply = try entry("answer", rev: 3, conversation: conversation.rawValue,
                                  author: "corey", text: "I can bring that.", extra: ["replyTo": .string("question")])
            var thread = RoomThread(conversation)
            thread.apply(question)
            thread.apply(try entry("reaction", rev: 2, kind: "reaction", conversation: conversation.rawValue,
                                   author: "corey", text: nil,
                                   extra: ["messageId": .string("question"), "emoji": .string("👍")]))
            thread.apply(reply)
            XCTAssertEqual(thread.messages.first?.reactions, [RoomReaction(author: "corey", emoji: "👍")])
            XCTAssertEqual(thread.messages.last?.text, "I can bring that.")
            XCTAssertEqual(thread.messages.last?.replyTo, "question")

            let page = try JSONValue.object([
                "messages": .array([try json(question), try json(reply)]), "hasMore": .bool(false),
                "reactions": .object(["question": .array([.object(["author": .string("corey"), "emoji": .string("👍")])])]),
                "reads": .array([]), "participants": .array([]),
                "self": .object(["person": .string("franco"), "assistant": .string("corey")]),
                "sessionKeys": .object([:]),
            ]).decoded(as: RoomHistoryPage.self)
            var reopened = RoomThread(conversation)
            reopened.load(page)
            XCTAssertEqual(reopened.messages.first?.reactions, thread.messages.first?.reactions)
            XCTAssertEqual(reopened.messages.last?.text, "I can bring that.")
            XCTAssertEqual(reopened.messages.last?.replyTo, "question")
        }
    }

    func testAStreamThatEndedWithoutAReplyIsRemoved() {
        var thread = RoomThread(.direct)
        thread.stream(runId: "run-1", author: "corey", text: "Thinking out loud", replace: false)
        thread.endStream(runId: "run-1", failure: "The assistant could not finish that reply.")
        XCTAssertEqual(thread.messages.last?.status, .failed("The assistant could not finish that reply."))
    }

    func testAnOlderPageIsPutInFrontWithoutRepeatingAnything() throws {
        var thread = RoomThread(.family)
        thread.apply(try entry("m-3", rev: 3))
        thread.apply(try entry("m-4", rev: 4))
        let older = try JSONValue.object([
            "messages": .array([try json(entry("m-1", rev: 1)), try json(entry("m-3", rev: 3))]),
            "hasMore": .bool(true),
            "reactions": .object([:]),
            "reads": .array([]),
            "participants": .array([]),
            "self": .object(["person": .string("franco"), "assistant": .string("corey")]),
            "sessionKeys": .object([:]),
        ]).decoded(as: RoomHistoryPage.self)
        thread.loadOlder(older)
        XCTAssertEqual(thread.messages.map(\.id), ["m-1", "m-3", "m-4"])
        XCTAssertTrue(thread.hasOlder)
        XCTAssertEqual(thread.oldestRev, 1)
    }

    func testTheLatestPageKeepsSendsStillInFlight() throws {
        let page = try fixture("household-app-history-response").decoded(as: RoomHistoryPage.self)
        var thread = RoomThread(.family)
        thread.addPending(pending("m-9"))
        thread.load(page)
        XCTAssertEqual(thread.messages.last?.id, "m-9")
        XCTAssertEqual(thread.messages.count, 4)
    }

    func testUnreadIsWhatOthersWroteAfterThisPersonsReadMarker() throws {
        var thread = RoomThread(.family)
        thread.apply(try entry("m-1", rev: 1, author: "gia"))
        thread.apply(try entry("m-2", rev: 2, author: "corey"))
        thread.apply(try entry("m-3", rev: 3, author: "franco"))
        XCTAssertEqual(thread.unreadCount(for: "franco"), 2)
        thread.apply(try entry("read:family:franco", rev: 4, kind: "read", author: "franco", text: nil,
                                extra: ["messageId": .string("m-1")]))
        XCTAssertEqual(thread.unreadCount(for: "franco"), 1)
        thread.apply(try entry("read:family:franco", rev: 5, kind: "read", author: "franco", text: nil,
                                extra: ["messageId": .string("m-3")]))
        XCTAssertEqual(thread.unreadCount(for: "franco"), 0)
    }

    func testTheLatestRevisionIsTheHighestKept() throws {
        var thread = RoomThread(.family)
        XCTAssertNil(thread.latestRev)
        thread.apply(try entry("m-1", rev: 1))
        thread.apply(try entry("m-5", rev: 5))
        XCTAssertEqual(thread.latestRev, 5)
        XCTAssertEqual(thread.lastMessageId, "m-5")
    }

    func testTheViewerSwipesThroughEveryKeptPhotoAndVideoInOrder() throws {
        func media(_ letter: Character, _ kind: String) -> JSONValue {
            .object([
                "id": .string(String(repeating: letter, count: 64)),
                "kind": .string(kind),
                "mime": .string("application/octet-stream"),
                "bytes": .number(10),
            ])
        }
        var thread = RoomThread(.family)
        thread.apply(try entry("m-1", rev: 1, author: "gia", extra: ["media": .array([media("a", "photo"), media("b", "voice"), media("c", "video")])]))
        thread.apply(try entry("m-2", rev: 2, extra: ["media": .array([media("d", "file")])]))
        thread.apply(try entry("m-3", rev: 3, author: "corey", extra: ["media": .array([media("e", "photo"), media("f", "photo")])]))
        var sending = pending("m-9")
        sending.media = [RoomMedia(id: "pending:0", kind: .photo, mime: "image/jpeg", bytes: 10)]
        thread.addPending(sending)

        let viewable = thread.photosAndVideos
        XCTAssertEqual(viewable.map { String($0.media.id.prefix(1)) }, ["a", "c", "e", "f"])
        XCTAssertEqual(viewable.map(\.message.id), ["m-1", "m-1", "m-3", "m-3"])
    }

    // MARK: - Approval cards

    private func approvalCard(_ id: String, rev: Int) throws -> RoomEntry {
        try entry(id, rev: rev, conversation: "direct", author: "corey", text: "Needs your OK: Add to the family calendar", extra: [
            "approval": .object([
                "id": .string("plugin:\(id)"), "kind": .string("plugin"), "title": .string("Add to the family calendar"),
                "decisions": .array([.string("allow-once"), .string("deny")]),
            ]),
        ])
    }

    private func ended(_ messageId: String, rev: Int, _ state: String) throws -> RoomEntry {
        try entry("approval:\(messageId)", rev: rev, kind: "approval", conversation: "direct", author: "corey", text: nil, extra: [
            "messageId": .string(messageId), "state": .string(state),
        ])
    }

    func testAnApprovalCardWaitsUntilTheGatewaySaysHowItEnded() throws {
        var thread = RoomThread(.direct)
        thread.apply(try approvalCard("ap-1", rev: 1))
        XCTAssertEqual(thread.messages.first?.approval?.title, "Add to the family calendar")
        XCTAssertNil(thread.approvalOutcomes["ap-1"])

        thread.apply(try ended("ap-1", rev: 2, "approved"))

        XCTAssertEqual(thread.approvalOutcomes["ap-1"], .approved)
        XCTAssertEqual(thread.messages.map(\.id), ["ap-1"], "how it ended is not a bubble of its own")
    }

    func testAnApprovalCardArrivingMidReplyLeavesTheReplyStreaming() throws {
        var thread = RoomThread(.direct)
        thread.stream(runId: "run-1", author: "corey", text: "Let me put that on the calendar.", replace: false)

        thread.apply(try approvalCard("ap-1", rev: 1))

        XCTAssertEqual(thread.messages.map(\.id), ["ap-1", "run:run-1"])
        XCTAssertEqual(thread.messages.last?.text, "Let me put that on the calendar.")
    }

    func testAPageSaysHowItsApprovalCardsEndedAndKeepsWhatWasAlreadyKnown() throws {
        var thread = RoomThread(.direct)
        thread.apply(try approvalCard("ap-1", rev: 1))
        thread.apply(try ended("ap-1", rev: 2, "denied"))
        let page = try JSONValue.object([
            "messages": .array([try json(try approvalCard("ap-1", rev: 1)), try json(try approvalCard("ap-2", rev: 3))]),
            "hasMore": .bool(false), "reactions": .object([:]), "reads": .array([]),
            "approvals": .object(["ap-2": .string("expired"), "ap-3": .string("withdrawn")]),
            "participants": .array([]), "self": .object(["person": .string("franco"), "assistant": .string("corey")]),
            "sessionKeys": .object([:]),
        ]).decoded(as: RoomHistoryPage.self)

        thread.load(page)

        XCTAssertEqual(thread.approvalOutcomes, ["ap-1": .denied, "ap-2": .expired])
    }

    func testAVoiceNotesWordsArriveAfterItAndComeWithItsPage() throws {
        let voice: JSONValue = .array([.object([
            "id": .string(String(repeating: "a", count: 64)), "kind": .string("voice"),
            "mime": .string("audio/mp4"), "bytes": .number(2048), "durationMs": .number(3200),
        ])])
        let note = try entry("v-1", rev: 1, text: "", extra: ["media": voice])
        var thread = RoomThread(.family)
        thread.apply(note)
        XCTAssertNil(thread.messages[0].heard)

        thread.apply(try entry("transcript:v-1", rev: 2, kind: "transcript", author: "corey", text: nil,
                                extra: ["messageId": .string("v-1"), "words": .string("Corey, what's for dinner?")]))
        XCTAssertEqual(thread.messages[0].heard, "Corey, what's for dinner?")

        let page = try JSONValue.object([
            "messages": .array([try json(note)]),
            "hasMore": .bool(false), "reactions": .object([:]), "reads": .array([]),
            "transcripts": .object(["v-1": .string("Corey, what's for dinner?")]),
            "participants": .array([]), "self": .object(["person": .string("franco"), "assistant": .string("corey")]),
            "sessionKeys": .object([:]),
        ]).decoded(as: RoomHistoryPage.self)
        var reopened = RoomThread(.family)
        reopened.load(page)
        XCTAssertEqual(reopened.messages[0].heard, "Corey, what's for dinner?")
    }

    func testAVoiceNoteThisPhoneSentKeepsItsWordsWhenTheGatewayKeepsIt() throws {
        var thread = RoomThread(.family)
        thread.addPending(pending("v-2", text: ""))
        thread.apply(try entry("transcript:v-2", rev: 2, kind: "transcript", author: "corey", text: nil,
                                extra: ["messageId": .string("v-2"), "words": .string("Running late.")]))
        XCTAssertEqual(thread.messages[0].heard, "Running late.")

        thread.apply(try entry("v-2", rev: 1, text: ""))

        XCTAssertEqual(thread.messages.map(\.id), ["v-2"])
        XCTAssertEqual(thread.messages[0].heard, "Running late.")
    }

    private func fixture(_ name: String) throws -> JSONValue {
        guard case .response(let response) = try GatewayCodec.decode(try Fixtures.text(name)) else {
            throw XCTSkip("not a response")
        }
        return try XCTUnwrap(response.payload)
    }

    /// An entry back as the gateway's JSON, for building pages.
    private func json(_ entry: RoomEntry) throws -> JSONValue {
        var members: [String: JSONValue] = [
            "id": .string(entry.id), "rev": .number(Double(entry.rev)), "kind": .string(entry.kind.rawValue),
            "conversation": .string(entry.conversation), "author": .string(entry.author),
            "at": .number(Double(entry.at)), "origin": .string("local"),
        ]
        if let text = entry.text {
            members["text"] = .string(text)
            members["media"] = .array([])
        }
        if let replyTo = entry.replyTo {
            members["replyTo"] = .string(replyTo)
        }
        return .object(members)
    }
}
