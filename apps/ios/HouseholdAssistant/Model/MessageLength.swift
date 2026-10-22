// How long a person's message may be. The gateway refuses a longer one
// (MAX_PERSON_MESSAGE_UNITS in the household-app plugin's room.js), counting UTF-16 units
// as JavaScript counts a string, of the words as they are sent: trimmed (RoomModel.send).
// The composer says so before sending, rather than the message failing after.

import Foundation

enum MessageLength {
    static let most = 64_000
    static let refusal = "Too long to send. Split it into smaller messages."

    static func isTooLong(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count > most
    }
}
