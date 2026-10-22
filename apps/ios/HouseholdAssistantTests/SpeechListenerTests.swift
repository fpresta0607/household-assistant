#if canImport(UIKit)
// A microphone with no input is never tapped. iOS gives the microphone no input, a sample
// rate and a channel count of zero, while the sound cannot record, and input through it
// then fails, as an Objective-C exception where it cannot fail as an error, which Swift
// cannot catch. Build 13 crashed on such an exception in AVFAudio's CreateRecordingTap
// under SpeechListener.start, though its report does not say which condition failed. Sound
// set up only to play is how the test gives the microphone no input.
//
// Each step logs a checkpoint as it is reached, so a crash on the simulator that leaves no
// report still shows the last step it got to.

import AVFoundation
import XCTest
@testable import HouseholdAssistant

@MainActor
final class SpeechListenerTests: XCTestCase {
    override func tearDown() async throws {
        checkpoint("tearDown: giving the sound back")
        AudioFocus.giveBack()
        checkpoint("tearDown: sound given back")
    }

    func testAListenerWithNoMicrophoneInputSaysSoInsteadOfStarting() throws {
        // Arrange: the sound set up to play only, which gives the microphone no input.
        checkpoint("taking the sound to play only")
        try AudioFocus.take(.playback, mode: .spokenAudio)
        let session = AVAudioSession.sharedInstance()
        checkpoint("sound taken: category \(session.category.rawValue), input available \(session.isInputAvailable)")
        let microphone = microphoneFormat()
        checkpoint("probe engine released")
        guard microphone.sampleRate == 0 || microphone.channelCount == 0 else {
            checkpoint("the microphone has input, so the test stops here")
            XCTFail("This simulator gives the microphone input on sound that only plays (\(microphone)), so the test cannot reach a microphone with none.")
            return
        }
        checkpoint("creating the listener")
        let listener = SpeechListener()
        checkpoint("listener created")
        var failures: [String] = []
        listener.onFailure = { failures.append($0) }

        // Act
        checkpoint("starting the listener")
        listener.start()
        checkpoint("listener.start returned: failures \(failures), running \(listener.isRunning)")

        // Assert
        XCTAssertEqual(failures, ["The microphone is not available right now. Tap to try again."])
        XCTAssertFalse(listener.isRunning)
        checkpoint("assertions done, releasing the listener")
    }

    /// The microphone's hardware format, read off a probe engine. A node is read only while
    /// its engine lives, which a temporary engine does not, and whatever the read left to be
    /// released goes before the probe does, as the probe goes on return.
    private func microphoneFormat() -> AVAudioFormat {
        checkpoint("creating the probe engine")
        let probe = AVAudioEngine()
        checkpoint("probe engine created")
        return withExtendedLifetime(probe) { () -> AVAudioFormat in
            let format = autoreleasepool { () -> AVAudioFormat in
                checkpoint("reading the probe's input node")
                let input = probe.inputNode
                checkpoint("input node read, reading its input format")
                let read = input.inputFormat(forBus: 0)
                checkpoint("input format read: \(read)")
                return read
            }
            checkpoint("autorelease pool drained, releasing the probe engine")
            return format
        }
    }

    /// NSLog writes at once to standard error, which xcodebuild shows, and to the
    /// simulator's unified log, so the last checkpoint outlives a crash.
    private func checkpoint(_ step: String) {
        NSLog("SpeechListenerTests checkpoint: %@", step)
    }
}
#endif
