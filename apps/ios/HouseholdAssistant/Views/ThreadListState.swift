// What the thread's list shares with its rows and with the message lifted over it: how far
// the person has dragged the timestamps out, which every row follows, what each voice note
// shows of its words, which the lifted copy of a note shows the same, and the message a
// search just brought into view, which glows a moment.

import Observation
import SwiftUI

@MainActor
@Observable
final class ThreadListState {
    var timestampReveal: CGFloat = 0
    var showsTimestamps = false
    var voiceNotes = VoiceNoteDisclosures()
    /// The message a search just brought into view (ThreadSearchModel).
    var found: String?
}
