// Recording a voice note the way Telegram does it: hold the microphone, slide left to
// cancel, slide up to lock for hands-free, let go to send, and listen back to a locked
// note before it goes. And the bars and the speed a voice note is played back with.

import XCTest
@testable import HouseholdAssistant

final class VoiceNoteTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_792_018_800)

    func testHoldingThenLettingGoSendsWhatWasSaid() {
        var gesture = VoiceNoteGesture()
        gesture.press(at: start)
        XCTAssertEqual(gesture.phase, .holding)
        gesture.release(at: start.addingTimeInterval(3.2))
        XCTAssertEqual(gesture.phase, .finished(.send(durationMs: 3200)))
    }

    func testATapKeepsTheNoteRecordingHandsFreeUntilTheArrowSendsIt() {
        var gesture = VoiceNoteGesture()
        gesture.press(at: start)
        gesture.release(at: start.addingTimeInterval(0.3))
        XCTAssertEqual(gesture.phase, .locked, "a tap records hands-free, as a locked note does")
        gesture.send(at: start.addingTimeInterval(4))
        XCTAssertEqual(gesture.phase, .finished(.send(durationMs: 4000)))
    }

    func testSlidingFarEnoughLeftCancels() {
        var gesture = VoiceNoteGesture()
        gesture.press(at: start)
        gesture.drag(x: -60, y: 0)
        XCTAssertEqual(gesture.phase, .holding)
        XCTAssertEqual(gesture.cancelProgress, 0.5, accuracy: 0.001)
        gesture.drag(x: -VoiceNoteGesture.cancelDistance, y: 0)
        XCTAssertEqual(gesture.phase, .finished(.cancelled))
        gesture.release(at: start.addingTimeInterval(2))
        XCTAssertEqual(gesture.phase, .finished(.cancelled), "letting go after cancelling sends nothing")
    }

    func testSlidingUpLocksAndLettingGoKeepsRecording() {
        var gesture = VoiceNoteGesture()
        gesture.press(at: start)
        gesture.drag(x: 0, y: -40)
        XCTAssertEqual(gesture.lockProgress, 0.5, accuracy: 0.001)
        gesture.drag(x: 0, y: -VoiceNoteGesture.lockDistance)
        XCTAssertEqual(gesture.phase, .locked)
        gesture.release(at: start.addingTimeInterval(1))
        XCTAssertEqual(gesture.phase, .locked)
        gesture.send(at: start.addingTimeInterval(9))
        XCTAssertEqual(gesture.phase, .finished(.send(durationMs: 9000)))
    }

    func testTheThresholdsAreExactlyTheDistances() {
        var cancelling = VoiceNoteGesture()
        cancelling.press(at: start)
        cancelling.drag(x: -(VoiceNoteGesture.cancelDistance - 0.5), y: 0)
        XCTAssertEqual(cancelling.phase, .holding)
        cancelling.drag(x: -VoiceNoteGesture.cancelDistance, y: 0)
        XCTAssertEqual(cancelling.phase, .finished(.cancelled))

        var locking = VoiceNoteGesture()
        locking.press(at: start)
        locking.drag(x: 0, y: -(VoiceNoteGesture.lockDistance - 0.5))
        XCTAssertEqual(locking.phase, .holding)
        locking.drag(x: 0, y: -VoiceNoteGesture.lockDistance)
        XCTAssertEqual(locking.phase, .locked)
    }

    /// The way the finger has gone further is the one that counts, so a slide to cancel
    /// that drifts up never locks, and a slide up that drifts left never cancels.
    func testOnlyTheWayTheFingerWentFurtherCounts() {
        var gesture = VoiceNoteGesture()
        gesture.press(at: start)
        gesture.drag(x: -100, y: -90)
        XCTAssertEqual(gesture.phase, .holding, "90 points up is past the lock, but the slide is to the left")
        XCTAssertEqual(gesture.lockProgress, 0)
        XCTAssertEqual(gesture.cancelProgress, 100 / VoiceNoteGesture.cancelDistance, accuracy: 0.001)

        gesture.drag(x: -30, y: -VoiceNoteGesture.lockDistance)
        XCTAssertEqual(gesture.phase, .locked)
        XCTAssertEqual(gesture.cancelProgress, 0)
    }

    func testSlidingRightOrDownDoesNothing() {
        var gesture = VoiceNoteGesture()
        gesture.press(at: start)
        gesture.drag(x: 400, y: 400)
        XCTAssertEqual(gesture.phase, .holding)
        XCTAssertEqual(gesture.cancelProgress, 0)
        XCTAssertEqual(gesture.lockProgress, 0)
    }

    func testASecondPressDoesNotRestartTheNote() {
        var gesture = VoiceNoteGesture()
        gesture.press(at: start)
        gesture.press(at: start.addingTimeInterval(3))
        XCTAssertEqual(gesture.startedAt, start)
        gesture.release(at: start.addingTimeInterval(4))
        XCTAssertEqual(gesture.phase, .finished(.send(durationMs: 4000)))
    }

    // MARK: - Listening back

    func testStoppingALockedNoteKeepsItToListenBackTo() {
        var gesture = VoiceNoteGesture()
        gesture.press(at: start)
        gesture.drag(x: 0, y: -VoiceNoteGesture.lockDistance)
        gesture.stop(at: start.addingTimeInterval(6.4))
        XCTAssertEqual(gesture.phase, .reviewing(durationMs: 6400))
        XCTAssertFalse(gesture.isRecording, "a stopped note no longer records")
        XCTAssertTrue(gesture.isReviewing)

        gesture.tick(at: start.addingTimeInterval(VoiceNoteGesture.longest + 1))
        gesture.release(at: start.addingTimeInterval(30))
        XCTAssertEqual(gesture.phase, .reviewing(durationMs: 6400), "the clock and the finger no longer move it")

        gesture.send(at: start.addingTimeInterval(40))
        XCTAssertEqual(gesture.phase, .finished(.send(durationMs: 6400)), "it goes as long as it was when it stopped")
    }

    func testANoteListenedBackToCanStillBeThrownAway() {
        var gesture = VoiceNoteGesture()
        gesture.press(at: start)
        gesture.drag(x: 0, y: -VoiceNoteGesture.lockDistance)
        gesture.stop(at: start.addingTimeInterval(3))
        gesture.discard()
        XCTAssertEqual(gesture.phase, .finished(.cancelled))
    }

    func testANoteStoppedTooSoonIsNotKept() {
        var gesture = VoiceNoteGesture()
        gesture.press(at: start)
        gesture.drag(x: 0, y: -VoiceNoteGesture.lockDistance)
        gesture.stop(at: start.addingTimeInterval(0.3))
        XCTAssertEqual(gesture.phase, .finished(.tooShort))
    }

    func testOnlyALockedNoteCanBeStoppedOrSentByButton() {
        var gesture = VoiceNoteGesture()
        gesture.press(at: start)
        gesture.stop(at: start.addingTimeInterval(3))
        gesture.send(at: start.addingTimeInterval(3))
        XCTAssertEqual(gesture.phase, .holding, "a held note is sent by letting go")
    }

    /// The widget's microphone opens the app straight into a note with no finger on it.
    func testANoteCanStartAlreadyLocked() {
        var gesture = VoiceNoteGesture()
        gesture.startLocked(at: start)
        XCTAssertEqual(gesture.phase, .locked)
        XCTAssertTrue(gesture.isRecording)
        gesture.drag(x: -500, y: 0)
        gesture.release(at: start.addingTimeInterval(1))
        XCTAssertEqual(gesture.phase, .locked, "no finger moves it")
        gesture.send(at: start.addingTimeInterval(4))
        XCTAssertEqual(gesture.phase, .finished(.send(durationMs: 4000)))
    }

    func testALockedRecordingCanStillBeThrownAway() {
        var gesture = VoiceNoteGesture()
        gesture.press(at: start)
        gesture.drag(x: 0, y: -VoiceNoteGesture.lockDistance)
        gesture.discard()
        XCTAssertEqual(gesture.phase, .finished(.cancelled))
    }

    func testOnceLockedASlideNoLongerCancels() {
        var gesture = VoiceNoteGesture()
        gesture.press(at: start)
        gesture.drag(x: 0, y: -VoiceNoteGesture.lockDistance)
        gesture.drag(x: -500, y: 0)
        XCTAssertEqual(gesture.phase, .locked)
    }

    func testARecordingIsCutAtTheLongestANoteMayBe() {
        var gesture = VoiceNoteGesture()
        gesture.press(at: start)
        gesture.tick(at: start.addingTimeInterval(VoiceNoteGesture.longest + 1))
        XCTAssertEqual(gesture.phase, .finished(.send(durationMs: Int(VoiceNoteGesture.longest * 1000))))
    }

    func testNothingHappensBeforeAPress() {
        var gesture = VoiceNoteGesture()
        gesture.drag(x: -500, y: -500)
        gesture.release(at: start)
        XCTAssertEqual(gesture.phase, .idle)
    }

    func testTheLevelsBecomeAFixedNumberOfBars() {
        let bars = Waveform.bars(from: [0, 0.2, 0.4, 0.6, 0.8, 1.0, 0.5, 0.25], count: 4)
        XCTAssertEqual(bars.count, 4)
        XCTAssertEqual(bars, [0.1, 0.5, 0.9, 0.375].map { max($0, Waveform.floor) }, "each bar is its bucket's mean")
    }

    func testAFewLevelsStretchToTheBarsAndSilenceStaysVisible() {
        XCTAssertEqual(Waveform.bars(from: [0.8], count: 3), [0.8, 0.8, 0.8])
        XCTAssertEqual(Waveform.bars(from: [], count: 3), [Waveform.floor, Waveform.floor, Waveform.floor])
        XCTAssertEqual(Waveform.bars(from: [0, 0], count: 2), [Waveform.floor, Waveform.floor])
    }

    /// A note's own audio, once it is on the phone: each bar is how loud its share of
    /// the samples is, so a full-scale wave fills the bar and silence sits on the floor.
    func testSamplesBecomeBarsOfTheirLoudness() {
        let loud: [Float] = (0..<400).map { $0 % 2 == 0 ? 1 : -1 }
        let silent = [Float](repeating: 0, count: 400)
        XCTAssertEqual(Waveform.bars(fromSamples: loud + silent, count: 4), [1, 1, Waveform.floor, Waveform.floor])
    }

    /// The same scale as the recorder's meter, so a note looks the same drawn either way.
    func testSamplesAreMeasuredOnTheMetersScale() {
        let twentyFiveDecibelsDown = Float(pow(10, -25.0 / 20))
        let bars = Waveform.bars(fromSamples: [Float](repeating: twentyFiveDecibelsDown, count: 90), count: 3)
        XCTAssertEqual(bars.count, 3)
        for bar in bars {
            XCTAssertEqual(bar, Waveform.level(decibels: -25), accuracy: 0.0001)
        }
    }

    func testAFewSamplesStillFillEveryBar() {
        XCTAssertEqual(Waveform.bars(fromSamples: [1], count: 3), [1, 1, 1])
        XCTAssertEqual(Waveform.bars(fromSamples: [], count: 3), [Waveform.floor, Waveform.floor, Waveform.floor])
        XCTAssertEqual(Waveform.bars(fromSamples: [1, -1], count: 0), [])
    }

    func testDecibelsBecomeALevel() {
        XCTAssertEqual(Waveform.level(decibels: 0), 1)
        XCTAssertEqual(Waveform.level(decibels: -160), 0)
        XCTAssertEqual(Waveform.level(decibels: -25), 0.5, accuracy: 0.001)
    }

    func testTheSpeedChipGoesRoundOneAndAHalfAndTwo() {
        XCTAssertEqual(PlaybackSpeed.normal.next, .faster)
        XCTAssertEqual(PlaybackSpeed.faster.next, .fastest)
        XCTAssertEqual(PlaybackSpeed.fastest.next, .normal)
        XCTAssertEqual(PlaybackSpeed.allCases.map(\.label), ["1x", "1.5x", "2x"])
    }

    func testADurationReadsLikeAClock() {
        XCTAssertEqual(VoiceNoteGesture.clock(milliseconds: 4200), "0:04")
        XCTAssertEqual(VoiceNoteGesture.clock(milliseconds: 65_000), "1:05")
        XCTAssertEqual(VoiceNoteGesture.clock(milliseconds: 0), "0:00")
    }
}
