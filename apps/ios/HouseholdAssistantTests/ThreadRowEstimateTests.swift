// A row not drawn yet stands at a height near the one it will draw at: taller with more
// words, cards, pictures and voice notes, and a card's own JSON never counted as words.

import XCTest
@testable import HouseholdAssistant

final class ThreadRowEstimateTests: XCTestCase {
    private static let width: CGFloat = 390

    private func row(_ text: String, media: [RoomMedia] = [], readers: [String]? = nil) -> ThreadRow {
        let message = RoomMessage(id: "d-1", author: "corey", text: text, media: media, replyTo: nil, sentAt: Date(), status: .sent)
        let content = ThreadRow.Message(
            message: message,
            placement: BubblePlacement(startsRun: true, endsRun: true, divider: nil),
            isFirst: false,
            repliedTo: nil,
            replacedCarts: [],
            offersFollowups: false,
            readers: readers,
            isLifted: false
        )
        return ThreadRow(id: .message(bubble: "d-1", occurrence: 0), content: .message(content))
    }

    private func estimate(_ row: ThreadRow) -> CGFloat {
        ThreadRowEstimate.height(of: row, width: Self.width)
    }

    func testALongDevotionalStandsFarTallerThanAShortAnswer() {
        // Arrange
        let short = row("Done.")
        let devotional = row(String(repeating: "Start the day slowly and listen before you speak. ", count: 80))

        // Act
        let shortHeight = estimate(short)
        let devotionalHeight = estimate(devotional)

        // Assert
        XCTAssertEqual(shortHeight, 12 + ThreadRowEstimate.lineHeight + ThreadRowEstimate.bubblePadding)
        XCTAssertGreaterThan(devotionalHeight, shortHeight * 20)
    }

    func testEachLineOfWordsCountsEvenWhenShort() {
        XCTAssertEqual(estimate(row("One\nTwo\nThree")) - estimate(row("One")), 2 * ThreadRowEstimate.lineHeight)
    }

    func testACardStandsAtACardsHeightAndItsJSONIsNotWords() {
        // Arrange
        let card = "```steward-card\n{\"type\":\"event\",\"title\":\"" + String(repeating: "Dinner ", count: 60) + "\"}\n```"

        // Act
        let height = estimate(row("Dinner is on:\n\n" + card))

        // Assert
        XCTAssertEqual(height, estimate(row("Dinner is on:")) + ThreadRowEstimate.cardHeight)
    }

    func testPicturesStandOnceAndEachVoiceNoteAndFileOnItsOwn() {
        // Arrange
        let photo = RoomMedia(id: "p", kind: .photo, mime: "image/jpeg", bytes: 1)
        let voice = RoomMedia(id: "v", kind: .voice, mime: "audio/mp4", bytes: 1)
        let file = RoomMedia(id: "f", kind: .file, mime: "application/pdf", bytes: 1)

        // Act
        let height = estimate(row("", media: [photo, photo, voice, voice, file]))

        // Assert
        XCTAssertEqual(
            height,
            12 + ThreadRowEstimate.pictureHeight + 2 * ThreadRowEstimate.voiceNoteHeight + ThreadRowEstimate.fileHeight
        )
    }

    func testTheReceiptUnderTheNewestOwnMessageAddsItsLine() {
        XCTAssertEqual(estimate(row("Hi", readers: [])) - estimate(row("Hi")), ThreadRowEstimate.receiptHeight)
    }

    func testRowsThatAreNotMessagesStandAtTheirOwnHeights() {
        let older = ThreadRow(id: .older, content: .older)
        let typing = ThreadRow(id: .typing("corey"), content: .typing(ThreadRow.Typing(participant: "corey", activity: nil)))
        XCTAssertEqual(estimate(older), 44)
        XCTAssertEqual(estimate(typing), 56)
    }
}
