#if DEBUG
// Franco's own thread shaped like the real one the owner found slow on build 14, for the
// UI test that times each thing he does in it (ChatSpeedTests): 46 entries over four days,
// five long Markdown replies of about 4,100, 3,450, 2,100, 2,000 and 1,950 characters, the
// rest short or middling, three calls, four voice notes and two photos. The words are the
// demo's own, never anything from the household.
//
// `-StewardHeavyThreadRepeats N` lays those four days down N times over, for a thread of
// thousands of messages, and hands all of it over in the first page, as a phone holds the
// thread once the person has read back through it.

import Foundation

enum DemoHeavyThread {
    static var isRequested: Bool {
        UserDefaults.standard.bool(forKey: "StewardHeavyThread")
    }

    /// How many times over the four days are laid down.
    static var repeats: Int {
        max(1, UserDefaults.standard.integer(forKey: "StewardHeavyThreadRepeats"))
    }

    /// The newest message, which the test waits for.
    static let newest = "Heavy thread newest message."

    private static let entriesEachTime = 44

    @MainActor
    static func stage(in room: DemoRoom) {
        let long = [4_100, 3_450, 2_100, 2_000, 1_950]
        let count = repeats * entriesEachTime
        if repeats > 1 {
            room.pageAtLeast = count + 2
        }
        var minutes = 4.0 * 24 * 60 + Double(count - entriesEachTime) * 110
        func step() -> Double {
            minutes -= 110
            return minutes
        }
        for each in 0..<count {
            let index = each % entriesEachTime
            let at = step()
            switch index {
            case 3, 12, 21, 30, 39:
                room.say(devotional(characters: long[(index - 3) / 9], round: each / entriesEachTime + 1), by: DemoRoom.assistant, in: .direct, minutesAgo: at)
            case 7, 26:
                room.say("", by: DemoRoom.person, in: .direct, minutesAgo: at, media: [room.photo])
            case 9, 18, 33, 41:
                room.say("", by: index % 2 == 0 ? DemoRoom.assistant : DemoRoom.person, in: .direct, minutesAgo: at, media: [room.voiceNote])
            case 15, 28, 36:
                room.call(lasting: 140, minutesAgo: at, words: [
                    (DemoRoom.person, "What is on tomorrow morning?"),
                    (DemoRoom.assistant, "School drop off at 7:45, then the dentist at 9."),
                ])
            default:
                if index % 2 == 0 {
                    room.say(questions[index % questions.count], by: DemoRoom.person, in: .direct, minutesAgo: at)
                } else {
                    room.say(answers[index % answers.count], by: DemoRoom.assistant, in: .direct, minutesAgo: at)
                }
            }
        }
        room.say("Thanks, that helps.", by: DemoRoom.person, in: .direct, minutesAgo: 6)
        room.say(newest, by: DemoRoom.assistant, in: .direct, minutesAgo: 5)
    }

    private static let questions = [
        "What's on this week?",
        "Can you move the dentist to Thursday?",
        "What do we need from the store?",
        "Send me this morning's reading again",
        "How long to Gia's office?",
    ]

    private static let answers = [
        "Here is the week:\n\n- **Monday** soccer at 5:45\n- **Tuesday** dentist at 3:30\n- **Thursday** recital at 6\n\nWant reminders for each?",
        "Done. The dentist is now Thursday at 3:30, and I told the office. I also moved the reminder, so it comes the evening before at 5, and again an hour ahead.",
        "From the list:\n\n1. Milk\n2. Eggs\n3. Bread\n4. Apples\n5. Coffee\n\nI can order them for Saturday morning, or you can pick them up on the way home tonight.",
        "About 18 minutes now. Traffic is light on Maple Street, and there is a slowdown near the bridge that should clear by the time you leave. *Leave by 5:20* to be early.",
    ]

    /// A morning reading the way a long scheduled reply is written: a heading, a quoted
    /// verse, paragraphs with bold and italic, and a short list, grown to `characters`.
    /// Each `round` of the four days reads differently, as no two real mornings repeat.
    static func devotional(characters: Int, round: Int) -> String {
        var text = "## Morning reading \(round)\n\n> *Be still, and know.* A verse to sit with this morning.\n\n"
        let paragraph = "**Today's thought.** Start the day slowly and *listen* before you speak. "
            + "Take a moment for the people around you, the small kindnesses, and the work in front of you, one thing at a time. "
            + "When the day gets loud, come back to this quiet place and breathe.\n\n"
        let list = "- Pause before the first meeting\n- Write down one thing you are grateful for\n- Call someone you love\n\n"
        var index = 0
        while text.count < characters {
            text += index % 4 == 3 ? list : paragraph
            index += 1
        }
        return text + "*Have a good day.*"
    }
}
#endif
