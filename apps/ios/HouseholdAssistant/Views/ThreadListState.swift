// What the thread's list shares with its rows and with the message lifted over it: which
// message the person is swiping and how far its timestamp is out, which that row alone
// follows, what each voice note
// shows of its words, which the lifted copy of a note shows the same, and the message a
// search just brought into view, which glows a moment.

import Observation
import SwiftUI

@MainActor
@Observable
final class ThreadListState {
    /// The message row a left swipe is on. Only that row moves and shows its timestamp, and
    /// only its cell reads `timestampReveal`, so a finger's move redraws one row, not all.
    var revealedRow: ThreadRow.ID?
    var timestampReveal: CGFloat = 0
    var showsTimestamps = false
    /// The message row under a point in the window, or nil; the thread's list answers it.
    @ObservationIgnored var rowAt: (CGPoint) -> ThreadRow.ID? = { _ in nil }
    var voiceNotes = VoiceNoteDisclosures()
    /// The message a search just brought into view (ThreadSearchModel).
    var found: String?
}
