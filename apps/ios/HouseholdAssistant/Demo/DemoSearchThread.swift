#if DEBUG
// Leo's own thread and the family room as the search tests find things in them
// (ConversationSearchTests, CFO notes section 5): 130 messages in his thread, more than the
// 100 a first page holds, so the oldest are only reached by reading older pages. The very
// first says when the plumber comes; three over the weeks mention the recital, the oldest
// beyond the first page; a beach photo is captioned "Seaside", and the field trip form is
// a file. In the family room Grandma's dinner is mentioned once, and Rosa's voice note says
// the pasta is getting cold. The words are the demo's own.

import Foundation

enum DemoSearchThread {
    static var isRequested: Bool {
        UserDefaults.standard.bool(forKey: "StewardSearchThread")
    }

    static let plumber = "The plumber comes Tuesday at 10 to fix the kitchen sink."
    static let grandma = "Grandma's birthday dinner is on the 12th, at her place."

    private static let count = 130

    @MainActor
    static func stage(in room: DemoRoom) {
        for index in 0..<count {
            let minutesAgo = Double(count - index) * 30 + 60
            let isLeo = index % 2 == 1
            switch index {
            case 0:
                room.say(plumber, by: DemoRoom.assistant, in: .direct, minutesAgo: minutesAgo)
            case 6:
                room.say("The recital moved to the school hall.", by: DemoRoom.assistant, in: .direct, minutesAgo: minutesAgo)
            case 70:
                room.say("Remember the recital program needs printing.", by: DemoRoom.assistant, in: .direct, minutesAgo: minutesAgo)
            case 91:
                room.say("Beach day at Seaside", by: DemoRoom.person, in: .direct, minutesAgo: minutesAgo, media: [room.photo])
            case 101:
                room.say("The trip form is attached", by: DemoRoom.person, in: .direct, minutesAgo: minutesAgo, media: [room.permissionSlip])
            case 124:
                room.say("The recital starts at 6, doors open at 5:30.", by: DemoRoom.assistant, in: .direct, minutesAgo: minutesAgo)
            default:
                room.say(
                    isLeo ? "What's next on day \(index)?" : "Day \(index): school run at 8, soccer at 5:45.",
                    by: isLeo ? DemoRoom.person : DemoRoom.assistant,
                    in: .direct,
                    minutesAgo: minutesAgo
                )
            }
        }
        room.say(grandma, by: "gia", minutesAgo: 200)
    }
}
#endif
