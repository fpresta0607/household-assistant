import XCTest
@testable import HouseholdAssistant

final class MessageSpeechTextTests: XCTestCase {
    func testLongMessageKeepsEveryWordWithinTheGatewayLimit() {
        let words = (0..<600).map { "Word\($0)." }
        let chunks = MessageSpeechText.chunks(words.joined(separator: "\n "))
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty && $0.utf16.count <= 400 })
        XCTAssertEqual(chunks.joined(separator: " "), words.joined(separator: " "))
    }

    func testUnbrokenUnicodeTextDoesNotBreakSurrogatePairsOrLoseContent() {
        let text = String(repeating: "🏡漢字", count: 350)
        let chunks = MessageSpeechText.chunks(text)
        XCTAssertEqual(chunks.joined(), text)
        XCTAssertTrue(chunks.allSatisfy { $0.utf16.count <= 400 && !$0.contains("�") })
    }

    func testEmptyTextNeverRequestsAudio() {
        XCTAssertTrue(MessageSpeechText.chunks(" \n\t ").isEmpty)
    }
}

#if canImport(UIKit)
@MainActor
final class MessageSpeechPlaybackTests: XCTestCase {
    func testStoppingWhileAudioIsLoadingCancelsItsReservation() {
        let player = VoiceNotePlayer.shared
        var stopped = 0
        player.reserve("message-speech:test:") { stopped += 1 }
        XCTAssertFalse(player.isPlaying)
        player.stop()
        player.stop()
        XCTAssertEqual(stopped, 1)
        XCTAssertNil(player.current)
    }

    func testAnotherPlaybackReservationStopsTheOldOneExactlyOnce() {
        let player = VoiceNotePlayer.shared
        var firstStopped = 0
        var secondStopped = 0
        player.reserve("message-speech:first:") { firstStopped += 1 }
        player.reserve("message-speech:second:") { secondStopped += 1 }
        XCTAssertEqual(firstStopped, 1)
        XCTAssertEqual(secondStopped, 0)
        player.stop()
        XCTAssertEqual(secondStopped, 1)
    }
}
#endif
