#if DEBUG
// Texts Corey drafted in Franco's own thread, for the UI tests of the Contacts connector and
// the message card (ContactsAndTextsTests): one for Kate and one for Anna with an event,
// people the Simulator's sample contacts have, and one for Zed, whom they do not. With it
// the demo may read and ask for Contacts (AppModel's shouldAskForContacts), and the tests
// answer iOS themselves. Never a real person's contacts: only the Simulator's own.

import Foundation

enum DemoContacts {
    static var isRequested: Bool {
        UserDefaults.standard.bool(forKey: "StewardContactsDemo")
    }

    @MainActor
    static func stage(in room: DemoRoom) {
        let calendar = Calendar.current
        let friday = calendar.date(byAdding: DateComponents(day: 3, hour: 20), to: calendar.startOfDay(for: Date())) ?? Date()
        let start = ISO8601DateFormatter().string(from: friday)
        let end = ISO8601DateFormatter().string(from: friday.addingTimeInterval(7200))
        let cards = [
            #"{"type":"message","to":"Kate","text":"Running 10 minutes late, see you soon."}"#,
            #"{"type":"message","to":"Anna","text":"Movie night at 8 at our place. The invite is attached.","event":{"title":"Movie night","start":"\#(start)","end":"\#(end)","location":"Living room"}}"#,
            #"{"type":"message","to":"Zed","text":"Thanks for the ride today!"}"#,
        ]
        for card in cards {
            room.say("Here it is, ready for you to send.\n\n```steward-card\n\(card)\n```", by: DemoRoom.assistant, in: .direct)
        }
    }
}
#endif
