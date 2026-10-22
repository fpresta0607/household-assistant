// A text its owner got, handed over by Shortcuts or Siri for the assistant to draft the
// reply: what the owner's own thread shows, with the sender when Shortcuts names one, and
// nothing at all for a text with no words.

import XCTest
@testable import HouseholdAssistant

final class ReceivedTextTests: XCTestCase {
    func testATextFromSomeoneAsksForTheReplyInTheOwnersWords() throws {
        // Act
        let text = try XCTUnwrap(ReceivedText(words: "  Are you all still coming Saturday?\n", sender: " Mike Rossi "))

        // Assert
        XCTAssertEqual(text.request, "A text from Mike Rossi:\n\u{201C}Are you all still coming Saturday?\u{201D}\nDraft my reply.")
    }

    func testATextWithNoSenderSaysOnlyThatItCame() throws {
        for sender in [nil, "", "  "] as [String?] {
            // Act
            let text = try XCTUnwrap(ReceivedText(words: "Need a headcount by tonight", sender: sender))

            // Assert
            XCTAssertNil(text.sender, "\(String(describing: sender))")
            XCTAssertEqual(text.request, "A text I got:\n\u{201C}Need a headcount by tonight\u{201D}\nDraft my reply.")
        }
    }

    func testATextWithNoWordsIsNothingToAnswer() {
        for words in ["", " ", "\n\t "] {
            XCTAssertNil(ReceivedText(words: words, sender: "Mike Rossi"), "\(words.debugDescription)")
        }
    }
}
