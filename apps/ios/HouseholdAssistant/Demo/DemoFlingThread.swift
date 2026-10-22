#if DEBUG
// Franco's own thread as a few hundred mixed rows, for the UI test that flings up through
// it fast (FastFlingTests, CFO notes sections 3 and 4): long Markdown replies, photos, bar
// and line charts, voice notes of his with their words and voice replies of Corey's, calls,
// and short and middling answers between them, 300 entries over about five days, all of it
// in the first page, as a phone holds the thread once the person has read back through it.
// What he sends there is answered at length, streamed word by word for about 15 seconds,
// so a test can fling while a reply streams in. The words are the demo's own.

import Foundation

enum DemoFlingThread {
    static var isRequested: Bool {
        UserDefaults.standard.bool(forKey: "StewardFlingThread")
    }

    /// The newest message, which the test waits for.
    static let newest = "Fling thread newest message."

    private static let rounds = 25
    private static let entriesEachRound = 12

    @MainActor
    static func stage(in room: DemoRoom) {
        let long = [4_100, 2_100, 3_450, 1_950, 2_000]
        let count = rounds * entriesEachRound
        room.pageAtLeast = count + 2
        var minutes = Double(count) * 25 + 30
        func step() -> Double {
            minutes -= 25
            return minutes
        }
        for round in 0..<rounds {
            room.say(questions[round % questions.count], by: DemoRoom.person, in: .direct, minutesAgo: step())
            room.say(DemoHeavyThread.devotional(characters: long[round % long.count], round: round + 1), by: DemoRoom.assistant, in: .direct, minutesAgo: step())
            room.say("", by: DemoRoom.person, in: .direct, minutesAgo: step(), media: [room.photo])
            room.say("Here is the spend by week.\n\n" + card(barChart) + "\n\nThe third week came in under the budget.", by: DemoRoom.assistant, in: .direct, minutesAgo: step())
            room.say("", by: DemoRoom.person, in: .direct, minutesAgo: step(), media: [room.voiceNote])
            room.say(answers[round % answers.count], by: DemoRoom.assistant, in: .direct, minutesAgo: step())
            room.say(questions[(round + 2) % questions.count], by: DemoRoom.person, in: .direct, minutesAgo: step())
            room.say("The living room through the day.\n\n" + card(lineChart), by: DemoRoom.assistant, in: .direct, minutesAgo: step())
            room.say(spokenReply, by: DemoRoom.assistant, in: .direct, minutesAgo: step(), media: [room.voiceNote])
            room.say(answers[(round + 1) % answers.count], by: DemoRoom.assistant, in: .direct, minutesAgo: step())
            room.call(lasting: 140, minutesAgo: step(), words: [
                (DemoRoom.person, "What is on tomorrow morning?"),
                (DemoRoom.assistant, "School drop off at 7:45, then the dentist at 9."),
            ])
            room.say("Thanks, that helps.", by: DemoRoom.person, in: .direct, minutesAgo: step())
        }
        room.say("One more thing for tonight?", by: DemoRoom.person, in: .direct, minutesAgo: 6)
        room.say(newest, by: DemoRoom.assistant, in: .direct, minutesAgo: 5)
    }

    /// Corey's answer to `asked`, long enough to stream for about 15 seconds, ending with the
    /// question so a test knows its own answer is all in.
    static func reply(to asked: String) -> String {
        DemoHeavyThread.devotional(characters: 2_400, round: 99) + "\n\nThat was your question \(asked)."
    }

    private static func card(_ json: String) -> String {
        "```steward-card\n\(json)\n```"
    }

    private static let barChart = #"{"type":"chart","title":"Grocery spend by week","kind":"bar","x":["W1","W2","W3","W4"],"series":[{"name":"Spend","values":[142,118,131,104]}],"unit":"$"}"#
    private static let lineChart = #"{"type":"chart","title":"Thermostat today","kind":"line","x":["12 AM","4 AM","8 AM","12 PM","4 PM","8 PM"],"series":[{"name":"Living room","values":[68,67,69,71,72.5,70]}],"unit":"°F"}"#

    private static let spokenReply = "Dinner is at 6:30, and Gia lands at 4:10, so there is time to pick her up first."

    private static let questions = [
        "What's on this week?",
        "Can you move the dentist to Thursday?",
        "What do we need from the store?",
        "Send me this morning's reading again",
        "How long to Gia's office?",
    ]

    private static let answers = [
        "Here is the week:\n\n- **Monday** soccer at 5:45\n- **Tuesday** dentist at 3:30\n- **Thursday** recital at 6\n\nWant reminders for each?",
        "Done. The dentist is now Thursday at 3:30, and I told the office.",
        "From the list:\n\n1. Milk\n2. Eggs\n3. Bread\n4. Apples\n5. Coffee\n\nI can order them for Saturday morning, or you can pick them up on the way home tonight.",
        "About 18 minutes now. Traffic is light on Maple Street, and there is a slowdown near the bridge that should clear by the time you leave. *Leave by 5:20* to be early.",
    ]
}
#endif
