// A voice note shows only itself until it is tapped, a tap shows its Transcript, a tap on
// that opens the words, and a note whose message left the screen shows only itself again.

import XCTest
@testable import HouseholdAssistant

final class VoiceNoteDisclosuresTests: XCTestCase {
    private let note = VoiceNoteDisclosures.key(message: "m1", note: 0)

    func testANoteShowsNothingUnderItUntilTapped() {
        let disclosures = VoiceNoteDisclosures()

        XCTAssertNil(disclosures.shown(note))
        XCTAssertFalse(disclosures.showsAny(of: "m1"))
    }

    func testATapOnTheNoteShowsItsTranscriptAndASecondFoldsItAway() {
        // Arrange
        var disclosures = VoiceNoteDisclosures()

        // Act
        disclosures.tapNote(note)

        // Assert
        XCTAssertEqual(disclosures.shown(note), .disclosure)
        disclosures.tapNote(note)
        XCTAssertNil(disclosures.shown(note))
    }

    func testATapOnTheTranscriptOpensAndFoldsTheWords() {
        // Arrange
        var disclosures = VoiceNoteDisclosures()
        disclosures.tapNote(note)

        // Act
        disclosures.tapDisclosure(note)

        // Assert
        XCTAssertEqual(disclosures.shown(note), .words)
        disclosures.tapDisclosure(note)
        XCTAssertEqual(disclosures.shown(note), .disclosure)
    }

    func testATapOnANoteWithItsWordsOpenFoldsEverythingAway() {
        // Arrange
        var disclosures = VoiceNoteDisclosures()
        disclosures.tapNote(note)
        disclosures.tapDisclosure(note)

        // Act
        disclosures.tapNote(note)

        // Assert
        XCTAssertNil(disclosures.shown(note))
    }

    func testVoiceOversActionOpensTheWordsAndFoldsThemAway() {
        // Arrange
        var disclosures = VoiceNoteDisclosures()

        // Act
        disclosures.toggleWords(note)

        // Assert
        XCTAssertEqual(disclosures.shown(note), .words)
        disclosures.toggleWords(note)
        XCTAssertNil(disclosures.shown(note))
    }

    func testClosingAMessageLeavesOtherMessagesNotesAsTheyAre() {
        // Arrange
        var disclosures = VoiceNoteDisclosures()
        let second = VoiceNoteDisclosures.key(message: "m1", note: 1)
        // An id that starts with the closed one's.
        let other = VoiceNoteDisclosures.key(message: "m10", note: 0)
        for tapped in [note, second, other] {
            disclosures.tapNote(tapped)
        }

        // Act
        disclosures.close(of: "m1")

        // Assert
        XCTAssertNil(disclosures.shown(note))
        XCTAssertNil(disclosures.shown(second))
        XCTAssertFalse(disclosures.showsAny(of: "m1"))
        XCTAssertEqual(disclosures.shown(other), .disclosure)
        XCTAssertTrue(disclosures.showsAny(of: "m10"))
    }
}
