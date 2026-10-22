// The message card: a text Corey or Denise drafts for its owner, who it is for found in
// the phone's own Contacts, and what the card says once Messages has sent it or he has
// cancelled.

import XCTest
@testable import HouseholdAssistant

final class MessageCardTests: XCTestCase {
    private func card(_ json: String) -> MessageSegment? {
        StewardCardParser.segments(in: "```steward-card\n\(json)\n```", isStreaming: false).first
    }

    private static let draft = MessageCard(to: "Rosa", text: "Running 10 minutes late, start without me.")

    private static let rosaMarlowe = MessageContact(id: "c-1", name: "Rosa Marlowe", names: ["Rosa", "Marlowe"], address: "+1 317 555 0142")
    private static let rosaRomano = MessageContact(id: "c-2", name: "Rosa Romano", names: ["Rosa", "Romano"], address: "rosa@romano.example")
    private static let rosalind = MessageContact(id: "c-3", name: "Rosalind Rossi", names: ["Rosalind", "Rossi"], address: "+1 317 555 0199")
    private static let rosaNoNumber = MessageContact(id: "c-4", name: "Rosa Bianchi", names: ["Rosa", "Bianchi"], address: nil)

    // MARK: - The card

    func testAMessageCardReadsWhoItIsForAndTheWords() {
        let found = card(#"{"type":"message","to":" Rosa ","text":"Running 10 minutes late, start without me."}"#)

        XCTAssertEqual(found, .card(StewardCard(content: .message(Self.draft), skill: nil)))
    }

    func testAMessageCardMissingWhoOrWhatIsShownAsItsJSON() {
        let cards = [
            #"{"type":"message","text":"Running late."}"#,
            #"{"type":"message","to":"","text":"Running late."}"#,
            #"{"type":"message","to":"Rosa","text":"  "}"#,
            #"{"type":"message","to":"Rosa"}"#,
        ]
        for json in cards {
            XCTAssertEqual(card(json), .code(json), json)
        }
    }

    func testAMessageCardReadsAsWhoItIsForAndTheWordsWhenCopied() {
        let text = "Here is a text for Rosa.\n\n```steward-card\n{\"type\":\"message\",\"to\":\"Rosa\",\"text\":\"Running late.\"}\n```"

        XCTAssertEqual(MessagePlainText.text(of: text, calendar: .current), "Here is a text for Rosa.\n\nTo Rosa: Running late.")
    }

    // MARK: - An event in the text

    func testAMessageCardCarriesAnEventWrittenAsAnEventCardIs() throws {
        // Arrange
        let json = #"{"type":"message","to":"Sarah","text":"Movie night at 8.","event":{"title":"Movie night","start":"2026-10-23T20:00:00-04:00","end":"2026-10-23T22:00:00-04:00","location":"Our place"}}"#
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-23T20:00:00-04:00"))
        let end = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-23T22:00:00-04:00"))

        // Act
        let found = card(json)

        // Assert
        let event = EventCard(title: "Movie night", start: start, end: end, location: "Our place")
        XCTAssertEqual(found, .card(StewardCard(content: .message(MessageCard(to: "Sarah", text: "Movie night at 8.", event: event)), skill: nil)))
    }

    func testAMessageCardWithAnEventItCannotReadIsShownAsItsJSON() {
        let cards = [
            #"{"type":"message","to":"Sarah","text":"Movie night.","event":{"title":"Movie night"}}"#,
            #"{"type":"message","to":"Sarah","text":"Movie night.","event":{"title":"Movie night","start":"2026-10-23T22:00:00-04:00","end":"2026-10-23T20:00:00-04:00"}}"#,
            #"{"type":"message","to":"Sarah","text":"Movie night.","event":"Friday at 8"}"#,
        ]
        for json in cards {
            XCTAssertEqual(card(json), .code(json), json)
        }
    }

    func testAMessageCardsEventIsCopiedAsItsLinesUnderTheText() throws {
        // Arrange
        let card = #"{"type":"message","to":"Sarah","text":"Movie night at 8.","event":{"title":"Movie night","start":"2026-10-23T20:00:00-04:00","location":"Our place"}}"#
        let text = "Here it is.\n\n```steward-card\n\(card)\n```"

        // Act
        let copied = MessagePlainText.text(of: text, calendar: .current)

        // Assert
        XCTAssertTrue(copied.hasPrefix("Here it is.\n\nTo Sarah: Movie night at 8.\nMovie night\n"), copied)
        XCTAssertTrue(copied.hasSuffix("\nOur place"), copied)
    }

    func testSomeoneChosenFromThePickerIsWhoItGoesTo() {
        // Arrange
        let picked = MessageContact(id: "c-9", name: "Sarah Lee", names: [], address: "+1 317 555 0123")
        var state = MessageCardState(card: Self.draft)
        state.recipient = .nobody

        // Act
        state.recipient = .one(picked)

        // Assert
        XCTAssertEqual(state.address, "+1 317 555 0123")
        XCTAssertEqual(state.recipientName(of: Self.draft), "Sarah Lee")
    }

    // MARK: - Finding who it is for

    func testOneContactByThatNameIsWhoItIsFor() {
        XCTAssertEqual(MessageRecipient.matching("Rosa", in: [Self.rosaMarlowe]), .one(Self.rosaMarlowe))
    }

    func testSeveralContactsByThatNameAreOfferedAsAChoice() {
        XCTAssertEqual(MessageRecipient.matching("Rosa", in: [Self.rosaMarlowe, Self.rosaRomano]), .several([Self.rosaMarlowe, Self.rosaRomano]))
    }

    func testNoContactByThatNameLeavesTheChoiceToMessages() {
        XCTAssertEqual(MessageRecipient.matching("Rosa", in: []), .nobody)
    }

    func testWithoutAccessToContactsNobodyIsLookedUp() {
        XCTAssertEqual(MessageRecipient.matching("Rosa", in: nil), .noAccess)
    }

    func testANameThatIsWholeBeatsOneThatOnlyStartsTheSame() {
        // Contacts finds "Rosalind" for "Rosa" too, since it matches the start of a name.
        XCTAssertEqual(MessageRecipient.matching("rosa", in: [Self.rosalind, Self.rosaMarlowe]), .one(Self.rosaMarlowe))
        XCTAssertEqual(MessageRecipient.matching("Rosa Marlowe", in: [Self.rosaMarlowe, Self.rosaRomano]), .one(Self.rosaMarlowe))
        XCTAssertEqual(MessageRecipient.matching("Rosal", in: [Self.rosalind]), .one(Self.rosalind), "with no whole match, what Contacts found stands")
    }

    func testAContactNoTextCanReachIsLeftOut() {
        XCTAssertEqual(MessageRecipient.matching("Rosa", in: [Self.rosaNoNumber]), .nobody)
        XCTAssertEqual(MessageRecipient.matching("Rosa", in: [Self.rosaNoNumber, Self.rosaMarlowe]), .one(Self.rosaMarlowe))
    }

    func testANameWithAccentsMatchesOneWithout() {
        let renee = MessageContact(id: "c-5", name: "Renée Marlowe", names: ["Renée", "Marlowe"], address: "+1 317 555 0101")

        XCTAssertEqual(MessageRecipient.matching("Renee", in: [renee]), .one(renee))
    }

    // MARK: - What the card says

    func testAFreshCardHoldsTheAssistantsWordsAndWaitsToBeSent() {
        let state = MessageCardState(card: Self.draft)

        XCTAssertEqual(state.words, Self.draft.text)
        XCTAssertNil(state.recipient)
        XCTAssertFalse(state.isSent)
        XCTAssertTrue(state.canSend)
    }

    func testOneMatchIsWhoTheSheetAddresses() {
        var state = MessageCardState(card: Self.draft)
        state.recipient = .one(Self.rosaMarlowe)

        XCTAssertEqual(state.address, "+1 317 555 0142")
        XCTAssertEqual(state.recipientName(of: Self.draft), "Rosa Marlowe")
    }

    func testOfSeveralTheOneHeChoseIsWhoTheSheetAddresses() {
        var state = MessageCardState(card: Self.draft)
        state.recipient = .several([Self.rosaMarlowe, Self.rosaRomano])
        XCTAssertNil(state.address, "until he chooses, To is his to fill in Messages")
        XCTAssertEqual(state.recipientName(of: Self.draft), "Rosa")

        state.chosen = Self.rosaRomano

        XCTAssertEqual(state.address, "rosa@romano.example")
        XCTAssertEqual(state.recipientName(of: Self.draft), "Rosa Romano")
    }

    func testWithNoMatchOrNoAccessTheSheetOpensWithAnEmptyTo() {
        var state = MessageCardState(card: Self.draft)
        for recipient in [MessageRecipient.nobody, .noAccess] {
            state.recipient = recipient

            XCTAssertNil(state.address)
            XCTAssertEqual(state.recipientName(of: Self.draft), "Rosa")
            XCTAssertTrue(state.canSend)
        }
    }

    func testSentInMessagesTheCardSaysSentAndCannotBeSentAgain() {
        var state = MessageCardState(card: Self.draft)
        state.words = "Running 15 minutes late."

        state.finish(.sent)

        XCTAssertTrue(state.isSent)
        XCTAssertFalse(state.canSend)
        XCTAssertEqual(state.words, "Running 15 minutes late.")
        XCTAssertNil(state.failure)
    }

    func testCancelledInMessagesTheCardStaysAsItWas() {
        var state = MessageCardState(card: Self.draft)
        state.recipient = .one(Self.rosaMarlowe)
        state.words = "Running 15 minutes late."
        let before = state

        state.finish(.cancelled)

        XCTAssertEqual(state, before)
        XCTAssertTrue(state.canSend)
    }

    func testAMessageThatFailedSaysSoAndCanBeSentAgain() {
        var state = MessageCardState(card: Self.draft)

        state.finish(.failed)

        XCTAssertFalse(state.isSent)
        XCTAssertTrue(state.canSend)
        XCTAssertEqual(state.failure, "Messages could not send it. You can try again.")

        state.finish(.sent)
        XCTAssertNil(state.failure)
    }

    func testWordsEditedAwayLeaveNothingToSend() {
        var state = MessageCardState(card: Self.draft)

        state.words = " \n "

        XCTAssertFalse(state.canSend)
    }
}
