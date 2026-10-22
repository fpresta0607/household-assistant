#if canImport(UIKit)
// A thread's answers are made ready from the newest, and only as many as the screens it opens
// on and the next few above, so a thread of thousands keeps the newest ready instead of
// pushing them out with its oldest.

import XCTest
@testable import HouseholdAssistant

@MainActor
final class MarkdownDocumentsTests: XCTestCase {
    private static let participants = [
        RoomParticipant(id: "franco", name: "Franco", kind: .person, isOwner: true),
        RoomParticipant(id: "corey", name: "Corey", kind: .assistant, isOwner: false),
    ]

    func testAReadingStyleChangeDoesNotReuseFontsBakedIntoTheOldDocument() async {
        let text = "A fresh **bold**, *italic* and [linked](https://example.com) answer " + UUID().uuidString
        let regular = ReadingStyle.standard
        let bold = ReadingStyle(size: .large, isBold: true)
        let large = ReadingStyle(size: .accessibility3, isBold: true)
        let first = await MarkdownDocuments.parse(text, style: regular)
        XCTAssertNil(MarkdownDocuments.document(for: text, style: bold))
        let second = await MarkdownDocuments.parse(text, style: bold)
        XCTAssertEqual(MarkdownDocuments.document(for: text, style: regular), first)
        XCTAssertEqual(MarkdownDocuments.document(for: text, style: bold), second)
        XCTAssertNil(MarkdownDocuments.document(for: text, style: large))
        let third = await MarkdownDocuments.parse(text, style: large)
        XCTAssertEqual(MarkdownDocuments.document(for: text, style: large), third)
        XCTAssertEqual(MarkdownDocuments.document(for: text, style: regular), first)
    }

    func testOnlyTheNewestAnswersAreMadeReadyAhead() async throws {
        // Arrange
        let run = UUID().uuidString
        let count = MarkdownDocuments.preparedAtMost + 50
        let answers = (0..<count).map { index in
            RoomMessage(
                id: "d-\(run)-\(index)",
                author: "corey",
                text: "Answer \(index) of run \(run), with **some** words.",
                media: [],
                replyTo: nil,
                sentAt: Date(timeIntervalSince1970: Double(index)),
                status: .sent
            )
        }

        let me = RoomSelf(person: "franco", assistant: "corey")
        func stretch(_ index: Int) throws -> String {
            try XCTUnwrap(RoomMarkdown.documentTexts(in: answers[index].text, participants: Self.participants, me: me).first)
        }

        // Act
        await MarkdownDocuments.prepare(answers, participants: Self.participants, me: me)

        // Assert
        XCTAssertNotNil(MarkdownDocuments.document(for: try stretch(count - 1)), "the newest answer was not made ready")
        XCTAssertNotNil(MarkdownDocuments.document(for: try stretch(count - MarkdownDocuments.preparedAtMost)))
        XCTAssertNil(MarkdownDocuments.document(for: try stretch(0)), "an answer far above the newest was parsed ahead")
    }

    func testOpeningReadinessOnlyDependsOnTheVisibleMessagesAndCurrentReadingStyle() async {
        let me = RoomSelf(person: "franco", assistant: "corey")
        let visible = RoomMessage(id: "visible", author: "corey", text: "Visible **reply** " + UUID().uuidString,
                                  media: [], replyTo: nil, sentAt: Date(), status: .sent)
        let older = RoomMessage(id: "older", author: "corey", text: "Older **reply** " + UUID().uuidString,
                                media: [], replyTo: nil, sentAt: Date(), status: .sent)
        XCTAssertFalse(MarkdownDocuments.areReady([visible], participants: Self.participants, me: me, style: .standard))
        await MarkdownDocuments.prepare([visible], participants: Self.participants, me: me)
        XCTAssertTrue(MarkdownDocuments.areReady([visible], participants: Self.participants, me: me, style: .standard))
        XCTAssertFalse(MarkdownDocuments.areReady([older], participants: Self.participants, me: me, style: .standard))
        XCTAssertFalse(MarkdownDocuments.areReady([visible], participants: Self.participants, me: me,
                                                style: ReadingStyle(size: .accessibility3, isBold: true)))
    }
}
#endif

