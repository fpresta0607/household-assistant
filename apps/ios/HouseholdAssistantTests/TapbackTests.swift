// The five tapbacks a long press offers, which typed text is one emoji to react with from
// the emoji keyboard, how a message's reactions sit on its bubble, an assistant's among
// them, and what VoiceOver says of them.

import XCTest
@testable import HouseholdAssistant

final class TapbackTests: XCTestCase {
    func testTheBarOffersTheFiveTapbacksInMessagesOrder() {
        XCTAssertEqual(Tapback.allCases.map(\.emoji), ["\u{2764}\u{FE0F}", "\u{1F44D}", "\u{1F602}", "\u{203C}\u{FE0F}", "\u{2753}"])
        XCTAssertEqual(Tapback.allCases.map(\.name), ["Heart", "Thumbs up", "Ha ha", "Exclamation marks", "Question mark"])
    }

    /// The gateway's household_react tool offers the same five, spelled the same way.
    func testTheAssistantsTapbacksAreTheSameFive() {
        XCTAssertEqual(Tapback(rawValue: "❤️"), .heart)
        XCTAssertEqual(Tapback(rawValue: "‼️"), .emphasis)
        XCTAssertNil(Tapback(rawValue: "\u{1F44E}"), "a thumbs down is not one of them")
    }

    func testOneEmojiFromTheKeyboardIsAReactionAndNothingElseIs() {
        let cases: [(name: String, typed: String, reaction: String?)] = [
            ("an owl", "\u{1F989}", "\u{1F989}"),
            ("a heart with the emoji selector", "\u{2764}\u{FE0F}", "\u{2764}\u{FE0F}"),
            ("a thumbs up with a skin tone", "\u{1F44D}\u{1F3FD}", "\u{1F44D}\u{1F3FD}"),
            ("a finger pointing up with a skin tone", "\u{261D}\u{1F3FD}", "\u{261D}\u{1F3FD}"),
            ("a family joined into one", "\u{1F469}\u{200D}\u{1F469}\u{200D}\u{1F467}", "\u{1F469}\u{200D}\u{1F469}\u{200D}\u{1F467}"),
            ("a flag", "\u{1F1FA}\u{1F1F8}", "\u{1F1FA}\u{1F1F8}"),
            ("a keycap", "1\u{FE0F}\u{20E3}", "1\u{FE0F}\u{20E3}"),
            ("one emoji with spaces round it", " \u{1F44D}\n", "\u{1F44D}"),
            ("nothing", "", nil),
            ("only spaces", "  ", nil),
            ("a letter", "a", nil),
            ("a letter with an accent", "e\u{0301}", nil),
            ("a digit", "1", nil),
            ("a hash", "#", nil),
            ("a copyright sign as text", "\u{00A9}", nil),
            ("two emoji", "\u{1F44D}\u{1F44D}", nil),
            ("words and an emoji", "ok \u{1F44D}", nil),
        ]
        for (name, typed, reaction) in cases {
            // Act
            let picked = Tapback.reaction(typed: typed)

            // Assert
            XCTAssertEqual(picked, reaction, name)
        }
    }

    func testEachEmojiIsOneBadgeInTheOrderItFirstArrivedWithEveryoneWhoChoseIt() {
        let reactions = [
            RoomReaction(author: "gia", emoji: Tapback.heart.emoji),
            RoomReaction(author: "denise", emoji: Tapback.laugh.emoji),
            RoomReaction(author: "corey", emoji: Tapback.heart.emoji),
        ]
        XCTAssertEqual(Tapback.badges(for: reactions), [
            Tapback.Badge(emoji: Tapback.heart.emoji, authors: ["gia", "corey"]),
            Tapback.Badge(emoji: Tapback.laugh.emoji, authors: ["denise"]),
        ])
        XCTAssertEqual(Tapback.badges(for: []), [])
    }

    func testAnEmojiFromBeforeTapbacksStillShows() {
        let owl = RoomReaction(author: "gia", emoji: "\u{1F989}")
        XCTAssertEqual(Tapback.badges(for: [owl]), [Tapback.Badge(emoji: "\u{1F989}", authors: ["gia"])])
    }

    func testVoiceOverSaysWhoReactedAndHowAsMessagesDoes() {
        let names = ["franco": "You", "gia": "Rosa", "corey": "Corey", "denise": "Denise"]
        let reactions = [
            RoomReaction(author: "gia", emoji: Tapback.heart.emoji),
            RoomReaction(author: "corey", emoji: Tapback.thumbsUp.emoji),
            RoomReaction(author: "denise", emoji: Tapback.laugh.emoji),
            RoomReaction(author: "franco", emoji: Tapback.emphasis.emoji),
            RoomReaction(author: "gia", emoji: Tapback.question.emoji),
            RoomReaction(author: "corey", emoji: "\u{1F989}"),
        ]
        XCTAssertEqual(
            Tapback.spoken(reactions) { names[$0] ?? $0 },
            "Rosa loved this, Corey liked this, Denise laughed at this, You emphasized this, Rosa questioned this, Corey reacted with \u{1F989}"
        )
        XCTAssertEqual(Tapback.spoken([]) { $0 }, "")
    }

    /// An assistant's tapback arrives from the gateway as any reaction does, and shows on the
    /// person's message beside the people's.
    func testAnAssistantsTapbackShowsOnAPersonsMessageLikeAnyonesAndIsTakenBackTheSameWay() throws {
        var thread = RoomThread(.family)
        thread.apply(try entry(["id": .string("m-1"), "rev": .number(1), "kind": .string("message"), "author": .string("gia"),
                                "text": .string("Dinner is on me tonight"), "media": .array([])]))
        thread.apply(try reaction(by: "franco", emoji: .string(Tapback.heart.emoji), rev: 2))
        thread.apply(try reaction(by: "corey", emoji: .string(Tapback.laugh.emoji), rev: 3))
        XCTAssertEqual(thread.messages[0].reactions, [
            RoomReaction(author: "franco", emoji: Tapback.heart.emoji),
            RoomReaction(author: "corey", emoji: Tapback.laugh.emoji),
        ])
        thread.apply(try reaction(by: "corey", emoji: .null, rev: 4))
        XCTAssertEqual(thread.messages[0].reactions, [RoomReaction(author: "franco", emoji: Tapback.heart.emoji)])
    }

    private func reaction(by author: String, emoji: JSONValue, rev: Int) throws -> RoomEntry {
        try entry([
            "id": .string("reaction:m-1:\(author)"), "rev": .number(Double(rev)), "kind": .string("reaction"),
            "author": .string(author), "messageId": .string("m-1"), "emoji": emoji,
        ])
    }

    private func entry(_ members: [String: JSONValue]) throws -> RoomEntry {
        var all = members
        all["conversation"] = .string("family")
        all["at"] = .number(1_792_018_800_000)
        all["origin"] = .string("local")
        return try JSONValue.object(all).decoded(as: RoomEntry.self)
    }
}
