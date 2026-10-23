// What the thread's list shares with its rows and with the message lifted over it: which
// words each voice note shows, which the lifted copy of a note shows the same, and the message a
// search just brought into view, which glows a moment.

import Observation
import SwiftUI

@MainActor
@Observable
final class ThreadListState {
    var voiceNotes = VoiceNoteDisclosures()
    /// The message a search just brought into view (ThreadSearchModel).
    var found: String?
}
