// Splitting a streaming reply into the whole sentences Talk says aloud.

import XCTest
@testable import HouseholdAssistant

final class SpokenSentencesTests: XCTestCase {
    func testALongOpeningStartsAtANaturalClauseAndTheRestStaysTogether() {
        let opening = "Your appointment with the dentist is still booked for tomorrow afternoon,"
        var sentences = SpokenSentences()
        XCTAssertEqual(sentences.take(from: opening, .arriving), [])
        XCTAssertEqual(sentences.take(from: opening + " and", .arriving), [opening])
        XCTAssertEqual(sentences.take(from: opening + " and", .arriving), [])
        let rest = "and I can check the address for you, if you need it."
        XCTAssertEqual(sentences.take(from: opening + " " + rest, .finished), [rest])
    }

    func testShortOpeningsAndNumbersAreNotChoppedIntoFragments() {
        for reply in [
            "Yes, I can help with that",
            "The total for the entire renovation project including all materials is 12,345.67",
            "The appointment with your dentist tomorrow afternoon is at 12:30",
        ] {
            var sentences = SpokenSentences()
            XCTAssertEqual(sentences.take(from: reply, .arriving), [], reply)
            XCTAssertEqual(sentences.take(from: reply, .finished), [reply], reply)
        }
    }

    func testSentencesAreHandedOutAsSoonAsTheyAreWholeAndNeverTwice() {
        var sentences = SpokenSentences()
        XCTAssertEqual(sentences.take(from: "Standup at 9. Then lunch", .arriving), ["Standup at 9."])
        XCTAssertEqual(sentences.take(from: "Standup at 9. Then lunch", .arriving), [])
        XCTAssertEqual(
            sentences.take(from: "Standup at 9. Then lunch with Gia at 12:30. Want a", .arriving),
            ["Then lunch with Gia at 12:30."]
        )
        XCTAssertEqual(
            sentences.take(from: "Standup at 9. Then lunch with Gia at 12:30. Want a reminder?", .finished),
            ["Want a reminder?"]
        )
        XCTAssertEqual(sentences.take(from: "Standup at 9. Then lunch with Gia at 12:30. Want a reminder?", .finished), [])
    }

    func testOnlyACertainEndEndsASentenceWhileTheReplyArrives() {
        let cases: [(reply: String, whole: [String])] = [
            ("Dr. Lee is in at 3.30 p.m. on Friday. Then", ["Dr. Lee is in at 3.30 p.m. on Friday."]),
            ("Wait... what? Yes! Fine", ["Wait...", "what?", "Yes!"]),
            ("He said \u{201C}go.\u{201D} Then", ["He said \u{201C}go.\u{201D}"]),
            ("**Note.** Then", ["Note."]),
            ("It costs 3.", []),
            ("A period at the very end.", []),
            ("Born in 1990. Then", ["Born in 1990."]),
            ("J. R. R. Tolkien wrote it. So", ["J. R. R. Tolkien wrote it."]),
            ("Eggs, milk, etc. and bread. Ok", ["Eggs, milk, etc. and bread."]),
        ]
        for (reply, whole) in cases {
            var sentences = SpokenSentences()
            XCTAssertEqual(sentences.take(from: reply, .arriving), whole, reply)
        }
    }

    func testWhatIsLeftIsSaidWhenTheReplyEnds() {
        var sentences = SpokenSentences()
        XCTAssertEqual(sentences.take(from: "It costs 3.", .arriving), [])
        XCTAssertEqual(sentences.take(from: "It costs 3.50 in total", .finished), ["It costs 3.50 in total"])
    }

    func testAPauseForAToolSaysTheWordsSoFarThenCarriesOn() {
        var sentences = SpokenSentences()
        XCTAssertEqual(sentences.take(from: "Let me check the calendar", .paused), ["Let me check the calendar"])
        XCTAssertEqual(
            sentences.take(from: "Let me check the calendar. You have the dentist at 3. Ok", .arriving),
            ["You have the dentist at 3."]
        )
    }

    func testEachLineIsASentenceAndMarkdownIsNotSpoken() {
        var sentences = SpokenSentences()
        let reply = """
            **Tonight**
            - 16:10 Gia lands
            * 18:30 Dinner *at home*
            1. Bring the [slides](https://example.com/slides)
            2) Check `the` ~~old~~ plan
            ## Notes
            > Quoted line
            - [x] Packed
            ---
            """
        XCTAssertEqual(sentences.take(from: reply, .finished), [
            "Tonight",
            "16:10 Gia lands",
            "18:30 Dinner at home",
            "Bring the slides",
            "Check the old plan",
            "Notes",
            "Quoted line",
            "Packed",
        ])
    }

    func testCardsAndCodeAreNotRead() {
        let card = """
            Here is Saturday:
            ```steward-card
            {"type":"checklist","title":"Saturday","items":[{"text":"Milk"}]}
            ```
            Have fun!
            ```
            ls -la
            ```
            That is all.
            """
        var sentences = SpokenSentences()
        XCTAssertEqual(sentences.take(from: card, .finished), ["Here is Saturday:", "Have fun!", "That is all."])
    }

    func testTheWordsBeforeACardAreSaidAsSoonAsTheCardBegins() {
        var sentences = SpokenSentences()
        XCTAssertEqual(
            sentences.take(from: "Here is Saturday:\n```steward-card\n{\"type\":\"check", .arriving),
            ["Here is Saturday:"]
        )
    }

    func testEmojiAreNotReadOutByName() {
        var sentences = SpokenSentences()
        XCTAssertEqual(
            sentences.take(from: "Done \u{1F9B7}. Gia lands at 4:10 \u{2708}\u{FE0F}\u{2764}\u{FE0F}! \u{1F44D}\u{1F3FD}", .finished),
            ["Done.", "Gia lands at 4:10!"]
        )
    }

    func testAReplyRewrittenShorterThanWhatWasSaidSaysNothingMore() {
        var sentences = SpokenSentences()
        XCTAssertEqual(sentences.take(from: "Hello there. How", .arriving), ["Hello there."])
        XCTAssertEqual(sentences.take(from: "Hi", .finished), [])
    }

    func testOneSentenceIsCleanedForTheVoice() {
        let cases: [(String, String?)] = [
            ("  **Bold** and _soft_ words ", "Bold and soft words"),
            ("snake_case stays", "snake_case stays"),
            ("![a photo](https://example.com/a.jpg) of the cake", "a photo of the cake"),
            ("See https://example.com/x for more.", "See for more."),
            ("\u{1F389}\u{1F389}", nil),
            ("- ", nil),
            ("***", nil),
        ]
        for (markdown, spoken) in cases {
            XCTAssertEqual(SpokenSentences.spoken(markdown), spoken, markdown)
        }
    }
}
