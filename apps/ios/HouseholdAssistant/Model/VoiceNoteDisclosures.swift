// What each voice note in a thread shows of its words (CFO notes section 4). A note shows
// only itself, its play button, waveform and length, until the person taps it off the play
// button: then a small Transcript shows under it, and a tap on that opens the words. Once
// its message has left the screen the note shows only itself again when it is back. So a
// note's height changes only when the person taps it, never because its words were heard
// after it was drawn, which grew old notes under the rows around them while the thread
// flung past.

import Foundation

struct VoiceNoteDisclosures: Equatable, Sendable {
    /// What a tapped note shows under itself.
    enum Shown: Equatable, Sendable {
        /// The small Transcript, which opens the words.
        case disclosure
        /// The words, under the Transcript that folds them away again.
        case words
    }

    /// Only the notes the person tapped, by `key`.
    private var shown: [String: Shown] = [:]

    /// The note at `index` among the media of the message `messageId`.
    static func key(message messageId: String, note index: Int) -> String {
        "\(messageId)#\(index)"
    }

    func shown(_ note: String) -> Shown? {
        shown[note]
    }

    /// A tap on the note itself shows its Transcript, or folds away whatever it shows.
    mutating func tapNote(_ note: String) {
        shown[note] = shown[note] == nil ? .disclosure : nil
    }

    /// A tap on the Transcript opens the words, or folds them away.
    mutating func tapDisclosure(_ note: String) {
        shown[note] = shown[note] == .words ? .disclosure : .words
    }

    /// VoiceOver's one action: the words straight away, or nothing again.
    mutating func toggleWords(_ note: String) {
        shown[note] = shown[note] == .words ? nil : .words
    }

    /// Whether any note of the message shows anything under it.
    func showsAny(of messageId: String) -> Bool {
        shown.keys.contains { Self.isNote($0, of: messageId) }
    }

    /// Every note of the message shows only itself again.
    mutating func close(of messageId: String) {
        shown = shown.filter { !Self.isNote($0.key, of: messageId) }
    }

    private static func isNote(_ note: String, of messageId: String) -> Bool {
        note.hasPrefix(messageId + "#")
    }
}
