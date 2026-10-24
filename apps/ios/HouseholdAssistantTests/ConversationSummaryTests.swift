// What a conversation's pin on Chats shows, and what the gateway has kept of a thread for
// the shared strip and the widgets: made from the thread alone, so neither changes while
// a reply streams in or the assistant works.

import XCTest
@testable import HouseholdAssistant

final class ConversationSummaryTests: XCTestCase {
    private func entry(
        _ id: String,
        rev: Int,
        kind: String = "message",
        author: String = "gia",
        text: String? = "hello",
        extra: [String: JSONValue] = [:]
    ) throws -> RoomEntry {
        var members: [String: JSONValue] = [
            "id": .string(id), "rev": .number(Double(rev)), "kind": .string(kind),
            "conversation": .string("family"), "author": .string(author),
            "at": .number(1_792_018_800_000 + Double(rev) * 60_000), "origin": .string("local"),
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

    private func thread(_ entries: [RoomEntry]) -> RoomThread {
        var thread = RoomThread(.family)
        for entry in entries {
            thread.apply(entry)
        }
        return thread
    }

    func testTheSummaryCountsWhatIsUnreadForThisPerson() throws {
        // Arrange
        var family = thread([
            try entry("m-1", rev: 1, author: "franco", text: "Who is picking up?"),
            try entry("m-2", rev: 2, author: "gia", text: "Me"),
            try entry("m-3", rev: 3, author: "denise", text: "Soccer ends at 6"),
        ])
        family.apply(try entry("read:family:franco", rev: 4, kind: "read", author: "franco", text: nil, extra: ["messageId": .string("m-2")]))

        // Act
        let summary = ConversationSummary(family, readBy: "franco", isTyping: true)

        // Assert
        XCTAssertEqual(summary.unread, 1)
        XCTAssertTrue(summary.isTyping)
        XCTAssertEqual(ConversationSummary(family, readBy: nil, isTyping: false).unread, 0, "nobody to count for until the room says who")
    }

    func testASendOnItsWayOrAReplyStreamingLeavesTheSummaryAsItWas() throws {
        // Arrange
        var family = thread([try entry("m-1", rev: 1, text: "Dinner is ready")])
        let before = ConversationSummary(family, readBy: "franco", isTyping: false)

        // Act
        family.addPending(RoomMessage(id: "m-2", author: "franco", text: "Coming", media: [], replyTo: nil, sentAt: Date(), status: .sending))
        family.stream(runId: "run-1", author: "corey", text: "Tonight is", replace: false)
        family.stream(runId: "run-1", author: "corey", text: " pasta", replace: false)

        // Assert
        XCTAssertEqual(ConversationSummary(family, readBy: "franco", isTyping: false), before)
    }

    func testAnEmptyConversationHasNoUnreadMessages() {
        // Act
        let summary = ConversationSummary(RoomThread(.direct), readBy: "franco", isTyping: false)

        // Assert
        XCTAssertEqual(summary, .empty)
        XCTAssertEqual(summary.unread, 0)
        XCTAssertFalse(summary.isTyping)
    }

    func testUnreadMessagesIncludeMediaAndLocationsWithoutWords() throws {
        // Arrange
        let media: (String, [String: JSONValue]) -> JSONValue = { kind, extra in
            var members: [String: JSONValue] = [
                "id": .string(String(repeating: "a", count: 64)), "kind": .string(kind),
                "mime": .string("application/octet-stream"), "bytes": .number(10),
            ]
            for (key, value) in extra {
                members[key] = value
            }
            return .object(members)
        }
        let location: (Bool) -> JSONValue = { isLive in
            var members: [String: JSONValue] = [
                "latitudeE6": .number(41_881_832), "longitudeE6": .number(-87_623_177),
                "accuracy": .number(12), "at": .number(1_792_018_800_000),
            ]
            if isLive {
                members["until"] = .number(1_792_022_400_000)
            }
            return .object(members)
        }
        let cases: [RoomEntry] = [
            try entry("m-1", rev: 1, text: "", extra: ["media": .array([media("photo", [:])])]),
            try entry("m-2", rev: 2, text: " ", extra: ["media": .array([media("voice", ["durationMs": .number(64_000)])])]),
            try entry("m-3", rev: 3, text: "", extra: ["location": location(false)]),
            try entry("m-4", rev: 4, text: "", extra: ["location": location(true)]),
            try entry("m-5", rev: 5, text: "Look", extra: ["media": .array([media("photo", [:])])]),
        ]

        for message in cases {
            // Act
            let summary = ConversationSummary(thread([message]), readBy: "franco", isTyping: false)

            // Assert
            XCTAssertEqual(summary.unread, 1, message.id)
        }
    }

    func testWhatWasKeptLeavesOutSendsOnTheirWayStreamingRepliesAndTheAssistantsWork() throws {
        // Arrange
        var direct = RoomThread(.direct)
        direct.apply(try JSONValue.object([
            "id": .string("d-1"), "rev": .number(1), "kind": .string("message"), "conversation": .string("direct"),
            "author": .string("franco"), "at": .number(1_792_018_800_000), "origin": .string("local"),
            "text": .string("What is on today?"), "media": .array([]),
        ]).decoded(as: RoomEntry.self))
        let kept = direct.kept

        // Act
        direct.addPending(RoomMessage(id: "d-2", author: "franco", text: "And tomorrow?", media: [], replyTo: nil, sentAt: Date(), status: .sending))
        direct.stream(runId: "run-1", author: "corey", text: "Dentist at", replace: false)

        // Assert
        XCTAssertEqual(direct.kept, kept)
        XCTAssertEqual(direct.kept.messages.map(\.id), ["d-1"])
    }
}
