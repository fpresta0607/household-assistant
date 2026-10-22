// A message is read once for each text it has: every later ask for a finished message is
// answered from what was kept, a reply still streaming is kept among a few of its own so
// it never pushes a finished message out, and neither keeps more than it holds.
//
// Each test reads texts no other test reads, since the readings are kept for the whole run.

import XCTest
@testable import HouseholdAssistant

final class StewardCardReadingTests: XCTestCase {
    private func block(_ json: String) -> String {
        "```steward-card\n\(json)\n```"
    }

    func testEveryAskForAFinishedMessageSharesOneReading() {
        let followups = #"{"type":"followups","items":[{"text":"Remind me at 3:45","icon":"reminder"}]}"#
        let text = "Booked \(UUID()).\n\n" + block(#"{"type":"copy","text":"4821","skill":"lists"}"#) + "\n" + block(followups)

        let segments = StewardCardParser.segments(in: text, isStreaming: false)
        let kept = StewardCardParser.finished.value(for: text)

        XCTAssertEqual(kept?.segments, segments)
        XCTAssertEqual(StewardCardParser.followups(in: text), kept?.followups)
        XCTAssertEqual(StewardCardParser.followups(in: text)?.items.map(\.text), ["Remind me at 3:45"])
        XCTAssertEqual(StewardCardParser.skill(in: text, isStreaming: false), .lists)
    }

    func testTheProseLeavesACardsLinkToTheCardAndKeepsTheReplysOwn() {
        let scripture = block(#"{"type":"scripture","reference":"Genesis 39:7","translation":"BSB","verses":[{"n":7,"text":"After some time his master's wife looked longingly at Joseph."}],"link":"https://www.bible.com/bible/111/GEN.39.7.NIV","skill":"scripture"}"#)
        let text = "Here is tonight's passage \(UUID()).\n\n\(scripture)\n\nThe study guide is at https://example.com/guide."

        let prose = StewardCardParser.prose(in: text)

        XCTAssertFalse(prose.contains("bible.com"), prose)
        XCTAssertTrue(prose.contains("https://example.com/guide"), prose)
        XCTAssertTrue(prose.contains("Here is tonight's passage"), prose)
    }

    func testAMessageThatIsOnlyACardHasNoProse() {
        let text = block(#"{"type":"scripture","reference":"John 3:16","translation":"BSB","verses":[{"n":16,"text":"For God so loved the world \#(UUID())."}],"link":"https://www.bible.com/bible/111/JHN.3.16.NIV","skill":"scripture"}"#)

        XCTAssertEqual(StewardCardParser.prose(in: text).trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    func testAReplysOwnTableKeepsTheLinkInItsCellsInTheProse() {
        let text = "| Dish \(UUID()) | Where |\n| --- | --- |\n| Lasagna | [menu](https://example.com/menu) |"

        let prose = StewardCardParser.prose(in: text)

        XCTAssertTrue(prose.contains("https://example.com/menu"), prose)
        XCTAssertTrue(prose.contains("Lasagna"), prose)
    }

    func testASecondAskIsAnsweredFromWhatWasKeptWithoutReadingAgain() {
        let text = "Kept once \(UUID())"
        _ = StewardCardParser.segments(in: text, isStreaming: false)
        // Whatever is kept for the text is what every later ask gets, so a marker put in its
        // place shows that none of them reads the text again.
        StewardCardParser.finished.insert(StewardCardParser.Reading(segments: [.code("marker")], followups: nil), for: text)

        let segments = StewardCardParser.segments(in: text, isStreaming: false)
        let words = MessagePlainText.text(of: text, calendar: .current)

        XCTAssertEqual(segments, [.code("marker")])
        XCTAssertEqual(words, "marker")
    }

    func testAReplyStreamingNeverPushesAFinishedMessageOut() {
        let finished = "Finished \(UUID())"
        _ = StewardCardParser.segments(in: finished, isStreaming: false)
        var arriving = "Arriving \(UUID())"

        for word in 0..<(StewardCardParser.finished.capacity + 50) {
            arriving += " word\(word)"
            _ = StewardCardParser.segments(in: arriving, isStreaming: true)
        }

        XCTAssertNotNil(StewardCardParser.finished.value(for: finished))
        XCTAssertLessThanOrEqual(StewardCardParser.streaming.count, StewardCardParser.streaming.capacity)
    }

    func testFinishedReadingsAreBounded() {
        let capacity = StewardCardParser.finished.capacity

        for index in 0..<(capacity + 20) {
            _ = StewardCardParser.segments(in: "Message \(index) \(UUID())", isStreaming: false)
        }

        XCTAssertEqual(StewardCardParser.finished.count, capacity)
    }

    func testAStreamingAndAFinishedReadingOfOneTextAreKeptApart() {
        let card = block(#"{"type":"copy","text":"4821"}"#)
        let text = "Code \(UUID()):\n" + card.dropLast(4)

        let streaming = StewardCardParser.segments(in: text, isStreaming: true)
        let finished = StewardCardParser.segments(in: text, isStreaming: false)

        XCTAssertEqual(streaming.last, .pendingCard, "a card still arriving is a placeholder")
        XCTAssertNotEqual(finished.last, .pendingCard, "once the reply is over it is read as well as it can be")
    }
}
