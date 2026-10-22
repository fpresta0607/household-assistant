#if DEBUG
// Corey's message in Franco's own thread with an @mention and a checklist, for the UI test
// that taps a link and a card's button inside a bubble now that a long-press opens the
// message menu and a left drag shows the times (CardTapsTests).

import Foundation

enum DemoCardTaps {
    static var isRequested: Bool {
        UserDefaults.standard.bool(forKey: "StewardCardTapsDemo")
    }

    @MainActor
    static func stage(in room: DemoRoom) {
        let list = #"{"type":"checklist","id":"tonight","title":"Tonight","items":[{"text":"Bring the garden notebook","done":false},{"text":"Lock the shed","done":false}]}"#
        room.say("Ask @Denise about Saturday too.\n\n```steward-card\n\(list)\n```", by: DemoRoom.assistant, in: .direct)
    }
}
#endif
