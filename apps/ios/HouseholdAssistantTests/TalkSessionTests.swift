// A call's hands-free loop: the microphone always on, a natural pause to end a turn,
// talking over the assistant, mute, the holding line when nothing is said, and the call
// on hold.

import XCTest
@testable import HouseholdAssistant

final class TalkSessionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_792_050_000)

    private func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    /// A call that sent `words` at two seconds in and is waiting for the reply.
    private func waiting(after words: String = "What's on tomorrow", firstHoldingLine: Int = 0) -> TalkSession {
        var session = TalkSession(firstHoldingLine: firstHoldingLine)
        _ = session.handle(.began)
        _ = session.handle(.heard(words, at: at(0)))
        _ = session.handle(.tick(at(2)))
        return session
    }

    /// A call saying the first of `reply`'s sentences, with the rest of the reply arrived.
    private func speaking(_ reply: String = "Rosa lands at 4:10. Then the recital at 6.") -> TalkSession {
        var session = waiting()
        _ = session.handle(.reply(reply, isFinished: true))
        return session
    }

    // MARK: - A turn

    func testAFullTurnIsHandsFree() {
        var session = TalkSession()
        XCTAssertEqual(session.handle(.began), .listen)
        XCTAssertEqual(session.phase, .listening)

        XCTAssertEqual(session.handle(.heard("What's on tomorrow", at: at(0))), .none)
        XCTAssertEqual(session.utterance.heard, "What's on tomorrow")
        XCTAssertEqual(session.handle(.tick(at(0.6))), .none)
        XCTAssertEqual(session.handle(.tick(at(0.71))), .send("What's on tomorrow"))
        XCTAssertEqual(session.phase, .waiting)
        XCTAssertEqual(session.utterance.heard, "", "the next words heard start afresh")

        XCTAssertEqual(session.handle(.reply("Standup at 9. Then", isFinished: false)), .say(["Standup at 9."]))
        XCTAssertEqual(session.phase, .speaking)
        XCTAssertEqual(session.handle(.reply("Standup at 9. Then lunch.", isFinished: true)), .say(["Then lunch."]))
        XCTAssertEqual(session.sentences, ["Standup at 9.", "Then lunch."])

        XCTAssertEqual(session.handle(.saidSentence), .none)
        XCTAssertEqual(session.saidCount, 1)
        XCTAssertEqual(session.handle(.saidSentence), .listen)
        XCTAssertEqual(session.phase, .listening)
        XCTAssertEqual(session.utterance.heard, "", "the next turn starts from nothing")
    }

    func testNothingIsSentBeforeSomethingIsSaid() {
        var session = TalkSession()
        _ = session.handle(.began)
        XCTAssertEqual(session.handle(.tick(at(30))), .none)
        _ = session.handle(.heard("", at: at(30)))
        XCTAssertEqual(session.handle(.tick(at(60))), .none)
        XCTAssertEqual(session.phase, .listening)
    }

    /// A short fragment is someone still finding what to say, so it waits a little longer.
    func testAShortFragmentWaitsALittleLongerBeforeItIsSent() {
        var session = TalkSession()
        _ = session.handle(.began)
        _ = session.handle(.heard("Hey Corey", at: at(0)))
        XCTAssertEqual(session.handle(.tick(at(1.5))), .none)
        XCTAssertEqual(session.handle(.tick(at(1.7))), .send("Hey Corey"))
    }

    func testSayingStopOnItsOwnEndsTheCall() {
        for stop in ["Stop.", "stop", "Stop stop!"] {
            var session = TalkSession()
            _ = session.handle(.began)
            _ = session.handle(.heard(stop, at: at(0)))
            XCTAssertEqual(session.handle(.tick(at(1.7))), .stop, stop)
            XCTAssertEqual(session.phase, .ended)
        }
        var session = TalkSession()
        _ = session.handle(.began)
        _ = session.handle(.heard("Don't stop the music", at: at(0)))
        XCTAssertEqual(session.handle(.tick(at(1.0))), .send("Don't stop the music"))
    }

    func testFarewellFinishesSpeakingBeforeEndingTheCall() {
        for words in ["Thank you", "Thanks Corey!", "Good bye Denise", "Okay, bye", "Thank you so much"] {
            var session = waiting(after: words)
            XCTAssertTrue(session.isClosingCall, words)
            XCTAssertEqual(session.handle(.tick(at(4))), .none, "No holding line for a farewell")
            XCTAssertEqual(session.handle(.reply("You're welcome. Goodbye!", isFinished: true)), .say(["You're welcome.", "Goodbye!"]))
            XCTAssertEqual(session.handle(.saidSentence), .none)
            XCTAssertEqual(session.phase, .speaking)
            XCTAssertEqual(session.handle(.saidSentence), .stop)
            XCTAssertEqual(session.phase, .ended)
        }
    }

    func testThanksWithAnotherRequestDoesNotEndTheCall() {
        for words in ["Thank you, can you check tomorrow?", "Don't say goodbye yet", "Tell Rosa I said goodbye"] {
            XCTAssertFalse(TalkSession.isFarewell(words))
        }
        var session = waiting(after: "Thanks")
        _ = session.handle(.reply("Goodbye!", isFinished: true))
        XCTAssertEqual(session.handle(.heard("Wait, one more question", at: at(4))), .interrupt)
        XCTAssertFalse(session.isClosingCall)
        XCTAssertEqual(session.handle(.tick(at(6))), .send("Wait, one more question"))
    }

    func testFarewellWithEmptyReplyOrUnavailableVoiceStillEnds() {
        var session = waiting(after: "Bye")
        XCTAssertEqual(session.handle(.reply("", isFinished: true)), .say(["Goodbye!"]))
        XCTAssertEqual(session.handle(.saidSentence), .stop)
        session = waiting(after: "Thanks")
        _ = session.handle(.voiceUsedUp)
        XCTAssertEqual(session.handle(.reply("Goodbye!", isFinished: true)), .stop)
    }

    func testWhileWaitingItShowsWhatTheAssistantIsDoing() {
        var session = waiting()
        XCTAssertNil(session.activity, "thinking")
        XCTAssertEqual(session.handle(.working(.calendar)), .none)
        XCTAssertEqual(session.activity, .calendar)
        XCTAssertEqual(session.handle(.working(nil)), .none)
        XCTAssertNil(session.activity)
    }

    func testWhatTheAssistantDidLastTimeIsForgottenWithTheNextQuestion() {
        var session = speaking()
        _ = session.handle(.working(.webSearch))
        _ = session.handle(.saidSentence)
        _ = session.handle(.saidSentence)
        _ = session.handle(.heard("And on Friday", at: at(10)))
        XCTAssertEqual(session.handle(.tick(at(12))), .send("And on Friday"))
        XCTAssertNil(session.activity)
        XCTAssertEqual(session.sentences, [])
        XCTAssertEqual(session.saidCount, 0)
    }

    /// The assistant's own line before a tool is said the moment the tool starts, and the
    /// call shows it thinking while the tool runs.
    func testAToolStartingMidReplySaysTheWordsSoFarThenThinks() {
        var session = waiting()
        XCTAssertEqual(session.handle(.reply("One sec, checking the thermostat", isFinished: false)), .none)
        XCTAssertEqual(session.handle(.working(.other)), .say(["One sec, checking the thermostat"]))
        XCTAssertEqual(session.phase, .speaking)
        XCTAssertEqual(session.handle(.saidSentence), .none, "the reply is not over")
        XCTAssertEqual(session.phase, .waiting, "thinking while the tool runs")
        XCTAssertEqual(
            session.handle(.reply("One sec, checking the thermostat. It's 72 inside.", isFinished: true)),
            .say(["It's 72 inside."])
        )
        XCTAssertEqual(session.phase, .speaking)
        XCTAssertEqual(session.handle(.saidSentence), .listen)
    }

    func testAReplyAllSaidBeforeItEndsListensOnceItEnds() {
        var session = waiting()
        XCTAssertEqual(session.handle(.reply("One. ", isFinished: false)), .say(["One."]))
        XCTAssertEqual(session.handle(.saidSentence), .none)
        XCTAssertEqual(session.phase, .waiting)
        XCTAssertEqual(session.handle(.reply("One. ", isFinished: true)), .listen)
        XCTAssertEqual(session.phase, .listening)
    }

    func testAReplyWithNothingToSayListensAgain() {
        var session = waiting()
        let cardOnly = "```steward-card\n{\"type\":\"checklist\",\"title\":\"Saturday\",\"items\":[]}\n```"
        XCTAssertEqual(session.handle(.reply(cardOnly, isFinished: false)), .none)
        XCTAssertEqual(session.handle(.reply(cardOnly, isFinished: true)), .listen)
        XCTAssertEqual(session.phase, .listening)
    }

    // MARK: - Talking over the assistant

    func testTalkingOverTheAssistantStopsItAtOnceAndOpensTheTurn() {
        // Arrange
        var session = speaking()

        // Act
        let effect = session.handle(.heard("Wait, which recital?", at: at(5)))

        // Assert
        XCTAssertEqual(effect, .interrupt)
        XCTAssertEqual(session.phase, .listening)
        XCTAssertTrue(session.isCut)
        XCTAssertEqual(session.sentences, ["Rosa lands at 4:10.", "Then the recital at 6."], "what was cut stays to be shown")
        XCTAssertEqual(session.utterance.heard, "Wait, which recital?", "the words that cut in are the start of the turn")
        XCTAssertEqual(session.handle(.reply("Rosa lands at 4:10. Then the recital at 6. More.", isFinished: true)), .none)
        XCTAssertEqual(session.handle(.saidSentence), .none)
        XCTAssertEqual(session.handle(.tick(at(6))), .send("Wait, which recital?"))
        XCTAssertFalse(session.isCut)
    }

    func testTalkingWhileItThinksCutsInToo() {
        var session = waiting()
        XCTAssertEqual(session.handle(.heard("Actually, and Saturday?", at: at(3))), .interrupt)
        XCTAssertEqual(session.phase, .listening)
        XCTAssertEqual(session.handle(.reply("Tomorrow is clear.", isFinished: true)), .none, "the reply it cut is not said")
        XCTAssertEqual(session.handle(.tick(at(4))), .send("Actually, and Saturday?"))
    }

    /// Echo cancellation can let a little of the voice through. What the recognizer makes
    /// of it is all words the voice said, which never cut in, and a turn that does cut in
    /// starts after them.
    func testTheVoicesOwnEchoIsNeverTakenForThePerson() {
        // Arrange
        var session = speaking()

        // Act and assert: the recognizer's words grow as it hears more of the same voice.
        for echo in ["Rosa lands at", "Rosa lands at 4:10.", ""] {
            XCTAssertEqual(session.handle(.heard(echo, at: at(4))), .none, echo)
            XCTAssertEqual(session.phase, .speaking)
        }
        XCTAssertEqual(session.handle(.heard("Rosa lands at 4:10. Wait, which recital?", at: at(5))), .interrupt)
        XCTAssertEqual(session.utterance.heard, "Wait, which recital?")
        _ = session.handle(.heard("Rosa lands at 4:10. Wait, which recital is it?", at: at(5.5)))
        XCTAssertEqual(session.handle(.tick(at(6.5))), .send("Wait, which recital is it?"))
    }

    /// A word or two that only ever stops someone always cuts in, though the voice said the
    /// same word this turn: echo cancellation takes the voice out, and the person must
    /// always be able to stop it. The voice's own longer phrase is still its echo.
    func testAShortStoppingWordCutsInEvenWhenTheVoiceSaidIt() {
        let reply = "Wait, no, hold on to that thought. Rosa lands at 4:10."
        for words in ["Wait", "No no", "Hold on", "Stop"] {
            // Arrange
            var session = speaking(reply)

            // Act
            let effect = session.handle(.heard(words, at: at(4)))

            // Assert
            XCTAssertEqual(effect, .interrupt, words)
        }
        var session = speaking(reply)
        XCTAssertEqual(session.handle(.heard("hold on to that", at: at(4))), .none, "the voice's own phrase")
    }

    // MARK: - Mute

    func testNothingHeardWhileMutedIsTakenOrCutsIn() {
        var session = speaking()
        XCTAssertEqual(session.handle(.muted(true)), .mute(true))
        XCTAssertEqual(session.handle(.heard("Wait, which recital?", at: at(5))), .none)
        XCTAssertEqual(session.phase, .speaking, "muted, nothing cuts in")
        _ = session.handle(.saidSentence)
        XCTAssertEqual(session.handle(.saidSentence), .listen)
        XCTAssertEqual(session.handle(.heard("Wait, which recital?", at: at(8))), .none)
        XCTAssertEqual(session.handle(.tick(at(20))), .none, "nothing said while muted is ever sent")
        XCTAssertEqual(session.utterance.heard, "")
    }

    /// The owner's rule: muting never cuts the assistant off. It finishes what it is saying.
    func testMutingNeverCutsTheAssistantOff() {
        var session = speaking()
        XCTAssertEqual(session.handle(.muted(true)), .mute(true), "the microphone, never the voice")
        XCTAssertEqual(session.phase, .speaking)
        XCTAssertEqual(session.handle(.saidSentence), .none)
        XCTAssertEqual(session.saidCount, 1)
        XCTAssertEqual(session.handle(.saidSentence), .listen, "said to its end")
        XCTAssertTrue(session.isMuted)
        XCTAssertFalse(session.isCut)
    }

    /// A reply still arriving when the person mutes is said as it comes, and a holding line
    /// is said while muted as well.
    func testAMutedCallStillHearsTheWholeReply() {
        var session = waiting()
        _ = session.handle(.muted(true))
        XCTAssertEqual(session.handle(.tick(at(3.5))), .hold(TalkSession.holdingLines[0]))
        XCTAssertEqual(session.handle(.reply("It's 72 inside. The heat", isFinished: false)), .say(["It's 72 inside."]))
        XCTAssertEqual(session.handle(.reply("It's 72 inside. The heat is on.", isFinished: true)), .say(["The heat is on."]))
        _ = session.handle(.saidSentence)
        _ = session.handle(.saidSentence)
        XCTAssertEqual(session.handle(.saidSentence), .listen)
    }

    func testOnlyHangingUpStopsTheAssistantMidSentence() {
        var session = speaking()
        _ = session.handle(.muted(true))
        XCTAssertEqual(session.handle(.tapped), .none, "a tap on the face does not stop it")
        XCTAssertEqual(session.phase, .speaking)
        XCTAssertEqual(session.handle(.hungUp), .stop)
        XCTAssertEqual(session.phase, .ended)
        XCTAssertEqual(session.handle(.saidSentence), .none)
        XCTAssertEqual(session.handle(.muted(false)), .none)
    }

    func testUnmutingPicksUpFromThere() {
        var session = TalkSession()
        _ = session.handle(.began)
        XCTAssertEqual(session.handle(.muted(true)), .mute(true))
        XCTAssertEqual(session.handle(.muted(true)), .none, "muted once")
        _ = session.handle(.heard("this is for the kids", at: at(1)))
        XCTAssertEqual(session.handle(.muted(false)), .mute(false))
        XCTAssertFalse(session.isMuted)
        _ = session.handle(.heard("What's on tomorrow", at: at(10)))
        XCTAssertEqual(session.handle(.tick(at(11))), .send("What's on tomorrow"))
    }

    /// Muting is silence: words said before it end their turn after the pause, as on a call.
    func testWordsSaidBeforeMutingStillEndTheirTurn() {
        var session = TalkSession()
        _ = session.handle(.began)
        _ = session.handle(.heard("Add milk to the list", at: at(0)))
        _ = session.handle(.muted(true))
        XCTAssertEqual(session.handle(.tick(at(1.0))), .send("Add milk to the list"))
    }

    func testAFailedCallCanBeMutedBeforeItIsTriedAgain() {
        var session = waiting()
        _ = session.handle(.failed("The microphone could not be started."))
        XCTAssertEqual(session.handle(.muted(true)), .mute(true))
        XCTAssertEqual(session.handle(.tapped), .listen)
        XCTAssertTrue(session.isMuted)
    }

    // MARK: - No dead air

    func testAHoldingLineIsSaidWhenNothingIsSaidForAMomentAndAHalf() {
        // Arrange: the words went at two seconds in.
        var session = waiting()

        // Act and assert
        XCTAssertEqual(session.handle(.tick(at(3.4))), .none)
        XCTAssertEqual(session.handle(.tick(at(3.5))), .hold("One sec."))
        XCTAssertEqual(session.phase, .speaking)
        XCTAssertTrue(session.isHolding)
        XCTAssertEqual(session.handle(.tick(at(9))), .none, "one a turn")
        XCTAssertEqual(session.handle(.saidSentence), .none)
        XCTAssertEqual(session.phase, .waiting, "thinking again once it is said")
        XCTAssertFalse(session.isHolding)
        XCTAssertEqual(session.saidCount, 0, "a holding line is not part of the reply")
        XCTAssertEqual(session.handle(.reply("Tomorrow is clear.", isFinished: true)), .say(["Tomorrow is clear."]))
        XCTAssertEqual(session.handle(.saidSentence), .listen)
    }

    func testNoHoldingLineOnceTheReplyHasBegun() {
        var started = waiting()
        _ = started.handle(.reply("Sure, the", isFinished: false))
        XCTAssertEqual(started.handle(.tick(at(5))), .none, "words are on their way")

        var ownLine = waiting()
        _ = ownLine.handle(.reply("One sec, checking the thermostat", isFinished: false))
        _ = ownLine.handle(.working(.other))
        _ = ownLine.handle(.saidSentence)
        XCTAssertEqual(ownLine.handle(.tick(at(5))), .none, "the assistant said its own line")
    }

    func testAReplyThatComesDuringTheHoldingLineIsSaidAfterIt() {
        var session = waiting()
        _ = session.handle(.tick(at(3.5)))
        XCTAssertEqual(session.handle(.reply("It's 72 inside.", isFinished: true)), .say(["It's 72 inside."]))
        XCTAssertEqual(session.handle(.saidSentence), .none, "the holding line ended")
        XCTAssertEqual(session.phase, .speaking)
        XCTAssertEqual(session.saidCount, 0)
        XCTAssertEqual(session.handle(.saidSentence), .listen)
    }

    func testTheHoldingLinesTakeTurnsSoNoneIsSaidTwiceRunning() {
        for first in TalkSession.holdingLines.indices {
            // Arrange
            var session = TalkSession(firstHoldingLine: first)
            _ = session.handle(.began)
            var said: [String] = []

            // Act: a turn after a turn, each one quiet long enough for its line.
            for turn in 0..<(TalkSession.holdingLines.count * 2) {
                let sentAt = Double(turn) * 10
                _ = session.handle(.heard("What about turn \(turn)", at: at(sentAt)))
                _ = session.handle(.tick(at(sentAt + 2)))
                if case .hold(let line) = session.handle(.tick(at(sentAt + 4))) {
                    said.append(line)
                }
                _ = session.handle(.saidSentence)
                _ = session.handle(.reply("Done.", isFinished: true))
                _ = session.handle(.saidSentence)
            }

            // Assert
            XCTAssertEqual(said.count, TalkSession.holdingLines.count * 2)
            XCTAssertEqual(said.first, TalkSession.holdingLines[first])
            XCTAssertTrue(zip(said, said.dropFirst()).allSatisfy { $0 != $1 }, "never the same one twice running")
            XCTAssertEqual(Set(said.prefix(TalkSession.holdingLines.count)), Set(TalkSession.holdingLines), "each before any again")
        }
    }

    func testTheHoldingLinesAreReadiedInTheOrderTheCallSaysThem() {
        // Arrange
        let session = TalkSession(firstHoldingLine: 2)

        // Act
        let inTurn = session.holdingLinesInTurn

        // Assert
        XCTAssertEqual(inTurn.first, TalkSession.holdingLines[2], "the first line a wait needs is readied first")
        XCTAssertEqual(inTurn.sorted(), TalkSession.holdingLines.sorted())
    }

    func testTheNextCallStartsOnTheLineAfterTheLastOneSaid() {
        // Arrange
        var session = waiting(firstHoldingLine: TalkSession.holdingLines.count - 1)

        // Act
        _ = session.handle(.tick(at(3.5)))

        // Assert
        XCTAssertEqual(session.holdingLine, TalkSession.holdingLines.last)
        XCTAssertEqual(session.nextHoldingLine, 0, "the next call does not open with the line this one said last")
    }

    func testTalkingOverTheHoldingLineCutsInButItsEchoDoesNot() {
        var session = waiting()
        _ = session.handle(.tick(at(3.5)))
        XCTAssertEqual(session.handle(.heard("One sec", at: at(3.8))), .none, "the holding line's own echo")
        XCTAssertEqual(session.handle(.heard("One sec never mind", at: at(4))), .interrupt)
        XCTAssertFalse(session.isHolding)
        XCTAssertEqual(session.utterance.heard, "never mind")
    }

    func testNoHoldingLineOnceTodaysVoiceIsUsedUp() {
        var session = waiting()
        _ = session.handle(.voiceUsedUp)
        XCTAssertEqual(session.handle(.tick(at(5))), .none)
    }

    // MARK: - On hold

    func testAHoldStopsTheVoiceAndTheCutSentenceIsSaidAgainAfter() {
        // Arrange: the first sentence said, the second cut off by a phone call.
        var session = speaking()
        _ = session.handle(.saidSentence)

        // Act
        let paused = session.handle(.held(true))
        let lateEnd = session.handle(.saidSentence)
        let resumed = session.handle(.held(false))

        // Assert
        XCTAssertEqual(paused, .pause)
        XCTAssertFalse(session.isHeld)
        XCTAssertEqual(lateEnd, .none, "the voice was stopped, so nothing it said counts")
        XCTAssertEqual(resumed, .say(["Then the recital at 6."]))
        XCTAssertEqual(session.phase, .speaking)
        XCTAssertEqual(session.handle(.saidSentence), .listen)
    }

    func testAReplyThatArrivesOnHoldIsSaidOnceTheCallComesOff() {
        var session = waiting()
        XCTAssertEqual(session.handle(.held(true)), .pause)
        XCTAssertEqual(session.handle(.working(.reminder)), .none)
        XCTAssertEqual(session.handle(.reply("Standup at 9. Then lunch.", isFinished: true)), .none, "nothing is said on hold")
        XCTAssertEqual(session.handle(.held(false)), .say(["Standup at 9.", "Then lunch."]))
        XCTAssertEqual(session.handle(.saidSentence), .none)
        XCTAssertEqual(session.handle(.saidSentence), .listen)
    }

    func testAReplyStillArrivingAfterTheHoldCarriesOnAsItComes() {
        var session = waiting()
        _ = session.handle(.held(true))
        _ = session.handle(.reply("Standup at 9. Then", isFinished: false))
        XCTAssertEqual(session.handle(.held(false)), .say(["Standup at 9."]))
        XCTAssertEqual(session.handle(.reply("Standup at 9. Then lunch.", isFinished: true)), .say(["Then lunch."]))
    }

    func testNothingHeardOnHoldCountsAndTheTurnStartsAfreshAfter() {
        var session = TalkSession()
        _ = session.handle(.began)
        _ = session.handle(.heard("What's on", at: at(0)))
        XCTAssertEqual(session.handle(.held(true)), .pause)
        XCTAssertEqual(session.handle(.heard("What's on tomorrow", at: at(0.5))), .none)
        XCTAssertEqual(session.handle(.tick(at(5))), .none, "no turn ends on hold")
        XCTAssertEqual(session.handle(.held(false)), .listen)
        XCTAssertEqual(session.phase, .listening)
        XCTAssertEqual(session.utterance.heard, "", "what was said before the hold is stale")
    }

    func testNoHoldingLineIsSaidOnHold() {
        var session = waiting()
        _ = session.handle(.held(true))
        XCTAssertEqual(session.handle(.tick(at(10))), .none)
        XCTAssertEqual(session.handle(.held(false)), .none, "still thinking, with nothing to say yet")
        XCTAssertEqual(session.phase, .waiting)
        XCTAssertEqual(session.handle(.tick(at(11))), .hold(TalkSession.holdingLines[0]), "the turn's one line, now that it can be said")
    }

    func testAHoldingLineCutOffByAHoldIsNotSaidAgain() {
        var session = waiting()
        XCTAssertEqual(session.handle(.tick(at(3.5))), .hold(TalkSession.holdingLines[0]))
        _ = session.handle(.held(true))
        XCTAssertFalse(session.isHolding)
        XCTAssertEqual(session.handle(.held(false)), .none)
        XCTAssertEqual(session.phase, .waiting)
        XCTAssertEqual(session.handle(.tick(at(9))), .none, "one holding line a turn")
    }

    func testOnlyAChangeOfHoldCounts() {
        var session = speaking()
        XCTAssertEqual(session.handle(.held(false)), .none)
        XCTAssertEqual(session.handle(.held(true)), .pause)
        XCTAssertEqual(session.handle(.held(true)), .none)
    }

    func testMuteAndHangUpStillWorkOnHold() {
        var session = TalkSession()
        _ = session.handle(.began)
        _ = session.handle(.held(true))
        XCTAssertEqual(session.handle(.muted(true)), .mute(true))
        XCTAssertEqual(session.handle(.held(false)), .listen)
        XCTAssertTrue(session.isMuted, "muted before the hold ended, muted after")

        _ = session.handle(.held(true))
        XCTAssertEqual(session.handle(.hungUp), .stop)
        XCTAssertEqual(session.phase, .ended)
        XCTAssertEqual(session.handle(.held(false)), .none)
    }

    func testAFailedCallStaysFailedOffHold() {
        var session = waiting()
        _ = session.handle(.failed("The gateway refused it."))
        _ = session.handle(.held(true))
        XCTAssertEqual(session.handle(.held(false)), .none)
        XCTAssertEqual(session.phase, .failed("The gateway refused it."))
    }

    // MARK: - Taps, hanging up and failures

    func testATapOnlyTriesAgainAfterAFailure() {
        var listening = TalkSession()
        _ = listening.handle(.began)
        for var session in [listening, waiting(), speaking()] {
            let phase = session.phase
            XCTAssertEqual(session.handle(.tapped), .none)
            XCTAssertEqual(session.phase, phase)
        }
    }

    func testHangingUpEndsTheCallWhateverItIsDoing() {
        var listening = TalkSession()
        _ = listening.handle(.began)
        var failed = waiting()
        _ = failed.handle(.failed("The gateway refused it."))
        for var session in [listening, waiting(), speaking(), failed] {
            XCTAssertEqual(session.handle(.hungUp), .stop)
            XCTAssertEqual(session.phase, .ended)
            XCTAssertEqual(session.handle(.hungUp), .none)
            XCTAssertEqual(session.handle(.heard("hello", at: at(9))), .none)
            XCTAssertEqual(session.handle(.reply("Hi.", isFinished: true)), .none)
        }
    }

    func testAFailureIsShownAndATapListensAgain() {
        var session = waiting()
        XCTAssertEqual(session.handle(.failed("The gateway refused it.")), .stop)
        XCTAssertEqual(session.phase, .failed("The gateway refused it."))
        XCTAssertEqual(session.handle(.reply("Late.", isFinished: true)), .none)
        XCTAssertEqual(session.handle(.tapped), .listen)
        XCTAssertEqual(session.phase, .listening)
        XCTAssertEqual(session.utterance.heard, "")
    }

    // MARK: - Today's voice used up

    func testWhenTodaysVoiceIsUsedUpTheReplyShowsInWordsAndTheTurnOpensAgain() {
        var session = speaking()
        XCTAssertEqual(session.handle(.voiceUsedUp), .listen)
        XCTAssertTrue(session.isVoiceUsedUp)
        XCTAssertEqual(session.phase, .listening)
        XCTAssertEqual(session.saidCount, session.sentences.count, "every sentence handed out shows in full")
    }

    func testAReplyStillArrivingShowsAsItComesOnceTheVoiceIsUsedUp() {
        var session = waiting()
        XCTAssertEqual(session.handle(.reply("Standup at 9. Then", isFinished: false)), .say(["Standup at 9."]))
        XCTAssertEqual(session.handle(.voiceUsedUp), .interrupt, "nothing more is said, and the microphone stays on")
        XCTAssertEqual(session.phase, .waiting)
        XCTAssertEqual(session.saidCount, 1)

        XCTAssertEqual(session.handle(.reply("Standup at 9. Then lunch. Then the dentist.", isFinished: false)), .none)
        XCTAssertEqual(session.sentences, ["Standup at 9.", "Then lunch."])
        XCTAssertEqual(session.saidCount, 2)
        XCTAssertEqual(session.phase, .waiting)

        XCTAssertEqual(session.handle(.reply("Standup at 9. Then lunch. Then the dentist.", isFinished: true)), .listen)
        XCTAssertEqual(session.sentences, ["Standup at 9.", "Then lunch.", "Then the dentist."])
        XCTAssertEqual(session.saidCount, 3)
    }

    func testTheVoiceStaysUsedUpForTheRestOfTheCall() {
        var session = speaking()
        _ = session.handle(.voiceUsedUp)
        _ = session.handle(.heard("And Friday", at: at(20)))
        XCTAssertEqual(session.handle(.tick(at(22))), .send("And Friday"))
        XCTAssertEqual(session.handle(.reply("Friday is clear.", isFinished: true)), .listen, "nothing is said aloud")
        XCTAssertTrue(session.isVoiceUsedUp)
        XCTAssertEqual(session.sentences, ["Friday is clear."])
        XCTAssertEqual(session.saidCount, 1)
    }

    func testAVoiceUsedUpWhileListeningIsOnlyNoted() {
        var session = TalkSession()
        _ = session.handle(.began)
        XCTAssertEqual(session.handle(.voiceUsedUp), .none)
        XCTAssertTrue(session.isVoiceUsedUp)
        XCTAssertEqual(session.phase, .listening)
    }
}

