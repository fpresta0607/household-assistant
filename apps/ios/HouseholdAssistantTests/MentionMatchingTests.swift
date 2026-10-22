// What counts as a mention, decided the way the gateways' mentions.js decides it, with
// the cases of tests/js/household_app_mentions.test.mjs. Then which names a bubble draws
// as mentions, which of them it lights, how VoiceOver says them, and the links an
// assistant's Markdown carries them in.

import XCTest
@testable import HouseholdAssistant

final class MentionMatchingTests: XCTestCase {
    private let room = [
        RoomParticipant(id: "franco", name: "Franco", kind: .person, isOwner: true),
        RoomParticipant(id: "gia", name: "Gia", kind: .person, isOwner: false),
        RoomParticipant(id: "corey", name: "Corey", kind: .assistant, isOwner: false, emoji: "\u{1F989}"),
        RoomParticipant(id: "denise", name: "Denise", kind: .assistant, isOwner: false, emoji: "\u{1F338}"),
    ]
    private let me = RoomSelf(person: "franco", assistant: "corey")

    func testAMentionIsMatchedTheWayTheGatewaysMatchIt() {
        let cases: [(text: String, name: String, isExpected: Bool)] = [
            ("@Corey can you check?", "Corey", true),
            ("can you check, @corey", "Corey", true),
            ("@COREY!", "Corey", true),
            ("(@Denise)", "Denise", true),
            ("Corey can you check?", "Corey", false),
            ("@Coreys list", "Corey", false),
            ("@Giant pumpkins", "Gia", false),
            ("mail franco@example.com", "example", false),
            ("mail franco@Gia", "Gia", false),
            ("", "Gia", false),
        ]
        for shot in cases {
            XCTAssertEqual(Mention.isMentioned(shot.name, in: shot.text), shot.isExpected, "\(shot.text) and \(shot.name)")
        }
    }

    /// An assistant's Telegram bot, which the other assistant learned to write in the
    /// household's Telegram group, mentions it, as tests/js/household_app_mentions.test.mjs has it.
    func testAnAssistantsTelegramBotIsAMentionOfItsName() {
        let cases: [(text: String, name: String, isExpected: Bool)] = [
            ("@Denise_the_woman_bot can you check?", "Denise", true),
            ("ask @corey_the_man_bot.", "Corey", true),
            ("@DeniseBot?", "Denise", true),
            ("@Denisebotany notes", "Denise", false),
        ]
        for shot in cases {
            XCTAssertEqual(Mention.isMentioned(shot.name, in: shot.text), shot.isExpected, "\(shot.text) and \(shot.name)")
        }
    }

    /// Corey wrote Denise's bot in the family room on 19 October. The bubble draws it as the
    /// mention a person's @ writes, over the whole of what was written.
    func testABubbleDrawsAnAssistantsTelegramBotAsItsName() {
        let text = "That one is Gia's. @Denise_the_woman_bot is she free? @Corey"

        let spans = Mention.spans(in: text, participants: room, me: me)

        XCTAssertEqual(spans.map(\.participant.id), ["denise", "corey"])
        XCTAssertEqual(spans.map { String(text[$0.range]) }, ["@Denise_the_woman_bot", "@Corey"])
        XCTAssertEqual(spans.map(\.shown), ["@Denise", "@Corey"])
        XCTAssertEqual(Mention.spoken(text, spans: spans), "That one is Gia's. mentions Denise is she free? mentions Corey")
        XCTAssertEqual(
            Mention.linked(text, spans: spans),
            "That one is Gia's. [@Denise](steward-mention:denise) is she free? [@Corey](steward-mention:corey)"
        )
    }

    func testANameWithADotIsMatchedAsWrittenNotAsAPattern() {
        XCTAssertTrue(Mention.isMentioned("J.R.", in: "@J.R. are you there?"))
        XCTAssertFalse(Mention.isMentioned("J.R.", in: "@JxR are you there?"))
    }

    func testNothingIsMentionedByAnEmptyName() {
        XCTAssertFalse(Mention.isMentioned("", in: "@Gia"))
    }

    func testEveryoneTheWordsMentionIsFoundInTheOrderTheyAreWritten() {
        let spans = Mention.spans(in: "@Denise and @Franco, ask @corey", participants: room, me: me)
        XCTAssertEqual(spans.map(\.participant.id), ["denise", "franco", "corey"])
        XCTAssertEqual(Mention.spans(in: "no one here", participants: room, me: me), [])
    }

    func testABubbleStylesEachMentionAsWrittenAndLightsThisPhonesOwn() {
        let text = "@Gia and @franco, ask @Corey or @Denise. Not @Giant, not mail@gia.com, twice @gia"

        let spans = Mention.spans(in: text, participants: room, me: me)

        XCTAssertEqual(spans.map { String(text[$0.range]) }, ["@Gia", "@franco", "@Corey", "@Denise", "@gia"])
        XCTAssertEqual(spans.map(\.isMine), [false, true, true, false, false])
        XCTAssertEqual(spans.map(\.participant.kind), [.person, .person, .assistant, .assistant, .person])
    }

    func testOfTwoNamesAtOneAtTheLongerIsMeant() {
        let family = room + [RoomParticipant(id: "gia-marie", name: "Gia Marie", kind: .person, isOwner: false)]
        let text = "@Gia Marie is here, @Gia too"

        let spans = Mention.spans(in: text, participants: family, me: me)

        XCTAssertEqual(spans.map(\.participant.id), ["gia-marie", "gia"])
        XCTAssertEqual(spans.map { String(text[$0.range]) }, ["@Gia Marie", "@Gia"])
    }

    func testWithNobodyKnownYetNothingIsAMentionOrLit() {
        XCTAssertEqual(Mention.spans(in: "@Corey", participants: [], me: nil), [])
        XCTAssertEqual(Mention.spans(in: "@Corey", participants: room, me: nil).map(\.isMine), [false])
    }

    func testVoiceOverSaysAMentionAsMentionsAndTheName() {
        let text = "@corey can you ask (@Denise)?"
        let spans = Mention.spans(in: text, participants: room, me: me)

        XCTAssertEqual(Mention.spoken(text, spans: spans), "mentions Corey can you ask (mentions Denise)?")
        XCTAssertEqual(Mention.spoken("no one", spans: []), "no one")
    }

    func testAnAssistantsMarkdownCarriesEachMentionAsALinkToWhoItNames() throws {
        let markdown = "**Done**, @Gia. I asked @denise_ too"
        let spans = Mention.spans(in: markdown, participants: room, me: me)

        let linked = Mention.linked(markdown, spans: spans)

        XCTAssertEqual(linked, "**Done**, [@Gia](steward-mention:gia). I asked [@denise](steward-mention:denise)_ too")
        XCTAssertEqual(Mention.linked("no one", spans: []), "no one")
    }

    func testANameWithMarkdownInItStaysWordsInsideItsLink() {
        let starred = [RoomParticipant(id: "jr", name: "J*R", kind: .person, isOwner: false)]
        let markdown = "hi @J*R"

        let linked = Mention.linked(markdown, spans: Mention.spans(in: markdown, participants: starred, me: me))

        XCTAssertEqual(linked, #"hi [@J\*R](steward-mention:jr)"#)
    }

    func testAMentionLinkNamesItsParticipantAndNoOtherLinkDoes() throws {
        let corey = try XCTUnwrap(room.first { $0.id == "corey" })

        XCTAssertEqual(Mention.url(for: corey).absoluteString, "steward-mention:corey")
        XCTAssertEqual(Mention.participantId(in: Mention.url(for: corey)), "corey")
        XCTAssertNil(Mention.participantId(in: try XCTUnwrap(URL(string: "https://example.com/corey"))))
        XCTAssertNil(Mention.participantId(in: try XCTUnwrap(URL(string: "steward://family"))))
    }
}
