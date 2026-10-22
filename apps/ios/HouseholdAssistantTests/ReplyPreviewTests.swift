#if canImport(UIKit)
// The reply strip and the quote over a reply read a message's words, not its Markdown or
// a card's JSON. The strip spelled out an assistant's bold as asterisks in run 38969231226.

import XCTest
@testable import HouseholdAssistant

final class ReplyPreviewTests: XCTestCase {
    func testAnAssistantsBoldReadsAsWordsWithoutAsterisks() {
        // Arrange
        let message = "Paragraph 1: **Every detail belongs here.** We keep the whole account."

        // Act
        let preview = String(ReplyPreview.text(of: message, isAssistant: true).characters)

        // Assert
        XCTAssertEqual(preview, "Paragraph 1: Every detail belongs here. We keep the whole account.")
    }

    func testAnAssistantsCardReadsAsItsLinesWithoutJSON() {
        // Arrange
        let message = """
        Here is a text for Rosa.

        ```steward-card
        {"type":"message","to":"Rosa","text":"Running late."}
        ```
        """

        // Act
        let preview = String(ReplyPreview.text(of: message, isAssistant: true).characters)

        // Assert
        XCTAssertEqual(preview, "Here is a text for Rosa.\n\nTo Rosa: Running late.")
    }

    func testAPersonsPlainWordsStayAsWritten() {
        // Arrange
        let message = "Can you find the field trip form?"

        // Act
        let preview = String(ReplyPreview.text(of: message, isAssistant: false).characters)

        // Assert
        XCTAssertEqual(preview, message)
    }
}
#endif
