// The waits the owner feels in a chat, as signposted intervals in the app itself: from the
// tap that opens a conversation to its newest row on screen, and from Send, for words or a
// voice note, to the sent message's row on screen, and from the app's start to the Today
// card on Chats, which shows from the phone's own copy. And from a finger landing on the
// microphone to the recording on screen, to it settled there with nothing still easing
// in, and to the microphone's input started behind it.
// The UI tests time these (ChatSpeedTests, ComposerGesturesTests), since a test reading
// the screen through accessibility is slow on a long thread and times its own reading too,
// and Instruments shows them.

import Foundation
import os

@MainActor
enum ChatTiming {
    static let subsystem = "com.siqstack.stewardai"
    static let category = "chat"
    static let opening: StaticString = "open"
    static let sendingWords: StaticString = "send"
    static let sendingVoiceNote: StaticString = "voice note"
    static let showingToday: StaticString = "today"
    static let showingRecording: StaticString = "voice note shown"
    static let settlingRecording: StaticString = "voice note settled"
    static let startingCapture: StaticString = "voice note capture"

    private static let signposter = OSSignposter(subsystem: subsystem, category: category)
    private static var open: OSSignpostIntervalState?
    private static var send: (name: StaticString, state: OSSignpostIntervalState)?
    private static var today: OSSignpostIntervalState?
    private static var recording: OSSignpostIntervalState?
    private static var settling: OSSignpostIntervalState?
    private static var capture: OSSignpostIntervalState?
    /// When the finger landed on the microphone, for the thread's log.
    private static var touchedAt: Date?

    /// A finger landed on the microphone: the recording on screen and its input are timed
    /// from here.
    static func touchedMicrophone() {
        recording = signposter.beginInterval(showingRecording)
        settling = signposter.beginInterval(settlingRecording)
        capture = signposter.beginInterval(startingCapture)
        touchedAt = Date()
    }

    /// The bar a note records in came on screen.
    static func recordingShown() {
        if let recording {
            signposter.endInterval(showingRecording, recording)
            self.recording = nil
            ThreadLog.note("voice note shown in \(millisecondsSinceTouch) ms")
        }
    }

    /// The recording on screen stopped changing: every animation the touch started has
    /// finished.
    static func recordingSettled() {
        if let settling {
            signposter.endInterval(settlingRecording, settling)
            self.settling = nil
            ThreadLog.note("voice note settled in \(millisecondsSinceTouch) ms")
        }
    }

    /// The microphone's input started for the note.
    static func captureStarted() {
        if let capture {
            signposter.endInterval(startingCapture, capture)
            self.capture = nil
            ThreadLog.note("voice note capture in \(millisecondsSinceTouch) ms")
        }
    }

    private static var millisecondsSinceTouch: Int {
        touchedAt.map { Int((Date().timeIntervalSince($0) * 1000).rounded()) } ?? -1
    }

    /// The app started, which the Today card on Chats is timed from.
    static func launched() {
        today = signposter.beginInterval(showingToday)
    }

    /// The Today card came on screen, which ends its timing the first time after a start.
    static func todayShown() {
        if let today {
            signposter.endInterval(showingToday, today)
            self.today = nil
        }
    }

    /// A conversation was asked for, from Chats, a notification or anywhere else.
    static func opened() {
        open = signposter.beginInterval(opening)
    }

    /// Send was tapped, for words when `isVoiceNote` is false.
    static func sent(isVoiceNote: Bool) {
        let name = isVoiceNote ? sendingVoiceNote : sendingWords
        send = (name, signposter.beginInterval(name))
    }

    /// A row of the open thread came on screen, its newest when `isNewest`. A newest message
    /// coming on screen after Send is the one sent, whether or not the gateway has kept it
    /// by then.
    static func appeared(_ row: ThreadRow, isNewest: Bool) {
        guard isNewest else {
            return
        }
        if let open {
            signposter.endInterval(opening, open)
            self.open = nil
        }
        if let send, case .message = row.content {
            signposter.endInterval(send.name, send.state)
            self.send = nil
        }
    }
}
