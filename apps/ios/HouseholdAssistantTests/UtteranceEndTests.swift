// When a call decides the person has finished speaking.
//
// The clock is a Date about 1.8 billion seconds from 1970, where a Double steps by about
// a quarter of a microsecond, so a moment meant to be past a pause is put clearly past it.

import XCTest
@testable import HouseholdAssistant

final class UtteranceEndTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_792_050_000)

    private func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    func testNothingHeardNeverEndsTheTurn() {
        var utterance = UtteranceEnd()
        XCTAssertFalse(utterance.isOver(at: at(60)))
        for silence in ["", "   ", "\n", "...", "?"] {
            utterance.hear(silence, at: at(0))
            XCTAssertFalse(utterance.isOver(at: at(60)), "\"\(silence)\" is not something said")
        }
    }

    func testACompletePhraseEndsAfterSevenTenthsButABreathDoesNot() {
        var utterance = UtteranceEnd()
        utterance.hear("What's the weather like", at: at(0))
        XCTAssertEqual(utterance.pauseNeeded, UtteranceEnd.pause)
        XCTAssertFalse(utterance.isOver(at: at(0.6)), "a breath")
        XCTAssertFalse(utterance.isOver(at: at(0.69)))
        XCTAssertTrue(utterance.isOver(at: at(0.71)))
    }

    func testCompleteShortAnswersDoNotWaitLikeUnfinishedFragments() {
        for answer in ["Yes!", "No", "Okay", "Thank you.", "Go ahead", "Sounds good", "Stop"] {
            var utterance = UtteranceEnd()
            utterance.hear(answer, at: at(0))
            XCTAssertEqual(utterance.pauseNeeded, UtteranceEnd.answerPause, answer)
            XCTAssertFalse(utterance.isOver(at: at(0.5)), answer)
            XCTAssertTrue(utterance.isOver(at: at(0.56)), answer)
        }
    }

    func testContinuingAfterAShortAnswerKeepsTheTurnOpen() {
        var utterance = UtteranceEnd()
        utterance.hear("Yes", at: at(0))
        utterance.hear("Yes but", at: at(0.4))
        XCTAssertEqual(utterance.pauseNeeded, UtteranceEnd.longerPause)
        XCTAssertFalse(utterance.isOver(at: at(1.9)))
        utterance.hear("Yes but make it tomorrow", at: at(1.9))
        XCTAssertFalse(utterance.isOver(at: at(2.5)))
        XCTAssertTrue(utterance.isOver(at: at(2.61)))
    }

    func testAVeryShortFragmentWaitsALittleLonger() {
        for fragment in ["Hey Corey", "So", "Okay so"] {
            var utterance = UtteranceEnd()
            utterance.hear(fragment, at: at(0))
            XCTAssertEqual(utterance.pauseNeeded, UtteranceEnd.longerPause, fragment)
            XCTAssertFalse(utterance.isOver(at: at(1.5)), fragment)
            XCTAssertTrue(utterance.isOver(at: at(1.7)), fragment)
        }
    }

    func testWordsThatStopMidPhraseWaitALittleLonger() {
        let cases: [(String, TimeInterval)] = [
            ("Add eggs and", UtteranceEnd.longerPause),
            ("Remind me to call the", UtteranceEnd.longerPause),
            ("What's on tomorrow, um", UtteranceEnd.longerPause),
            ("Text Rosa that I'm on my", UtteranceEnd.longerPause),
            ("Add eggs and milk", UtteranceEnd.pause),
            ("Remind me to call the dentist", UtteranceEnd.pause),
        ]
        for (words, pause) in cases {
            var utterance = UtteranceEnd()
            utterance.hear(words, at: at(0))
            XCTAssertEqual(utterance.pauseNeeded, pause, words)
        }
    }

    func testTheTurnEndsAPauseAfterTheWordsLastChanged() {
        var utterance = UtteranceEnd()
        utterance.hear("What's on", at: at(0))
        XCTAssertFalse(utterance.isOver(at: at(1.5)))
        XCTAssertTrue(utterance.isOver(at: at(1.7)))

        utterance.hear("What's on tomorrow", at: at(1.0))
        XCTAssertEqual(utterance.heard, "What's on tomorrow")
        XCTAssertFalse(utterance.isOver(at: at(1.6)))
        XCTAssertTrue(utterance.isOver(at: at(1.71)))
    }

    func testTheRecognizerTidyingUpDoesNotRestartTheClock() {
        let tidied = [
            "what's on tomorrow",
            "What's on tomorrow?",
            "What\u{2019}s on tomorrow.",
            "  what's   on tomorrow ",
        ]
        for later in tidied {
            var utterance = UtteranceEnd()
            utterance.hear("what's on tomorrow", at: at(0))
            utterance.hear(later, at: at(0.8))
            XCTAssertEqual(utterance.heard, later, "the newest writing is what shows")
            XCTAssertTrue(utterance.isOver(at: at(1.0)), "\"\(later)\" says nothing new")
        }
    }

    func testAWordThatChangesRestartsTheClock() {
        var utterance = UtteranceEnd()
        utterance.hear("remind me to bring the slides", at: at(0))
        utterance.hear("remind me to bring the slide", at: at(1.0))
        XCTAssertFalse(utterance.isOver(at: at(1.5)))
        XCTAssertTrue(utterance.isOver(at: at(2.0)))
    }

    func testWordsAreWhatIsSaidNotHowItIsWritten() {
        let cases: [(String, [String])] = [
            ("Stop.", ["stop"]),
            ("  STOP!  ", ["stop"]),
            ("Don\u{2019}t stop, it's fine", ["don't", "stop", "it's", "fine"]),
            ("Lunch at 12:30?", ["lunch", "at", "12", "30"]),
            ("'quoted'", ["quoted"]),
            ("", []),
            ("...", []),
        ]
        for (text, words) in cases {
            XCTAssertEqual(UtteranceEnd.words(in: text), words, text)
        }
    }

    /// What is left of a heard text once words already accounted for are taken off its
    /// front, as written, counted the way `words(in:)` counts them.
    func testDroppingWordsKeepsTheRestAsWritten() {
        let cases: [(Int, String, String)] = [
            (2, "One sec. Wait, which one?", "Wait, which one?"),
            (5, "Rosa lands at 4:10. Wait, which recital?", "Wait, which recital?"),
            (3, "Don\u{2019}t stop, it's fine", "fine"),
            (1, "'quoted' word", "word"),
            (0, "  Hello there", "Hello there"),
            (2, "One sec.", ""),
            (4, "One sec.", ""),
        ]
        for (count, text, rest) in cases {
            XCTAssertEqual(UtteranceEnd.dropping(count, wordsFrom: text), rest, text)
            XCTAssertEqual(UtteranceEnd.words(in: rest), Array(UtteranceEnd.words(in: text).dropFirst(count)), text)
        }
    }
}
