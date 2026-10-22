#if DEBUG
import Foundation

enum DemoLongMessages {
    static var isRequested: Bool {
        UserDefaults.standard.bool(forKey: "StewardMessageActionsDemo")
    }

    static var isHuman: Bool {
        UserDefaults.standard.bool(forKey: "StewardMessageActionsHuman")
    }

    static var text: String {
        let paragraphs = (1...64).map { index in
            "Paragraph \(index): " + (isHuman ? "Every detail belongs here." : "**Every detail belongs here.**")
                + " We are keeping the complete account of the garden, the library, the school visit and the evening walk, including the final words. 🏡"
        }.joined(separator: "\n\n")
        let internalCard = isHuman ? "" : "```steward-card\n{\"type\":\"followups\",\"items\":[{\"text\":\"Hidden fixture followup\",\"icon\":\"reminder\"}]}\n```\n\n"
        return paragraphs + "\n\n" + internalCard
            + "Final paragraph for \(isHuman ? "human" : "assistant") e2b61. The complete message ends here."
    }

    @MainActor
    static func stage(in room: DemoRoom) {
        for conversation in [RoomConversation.direct, .family] {
            room.say(text, by: isHuman ? DemoRoom.person : DemoRoom.assistant, in: conversation)
            let question = room.say("Please bring the garden notebook.", by: DemoRoom.person, in: conversation)
            room.react(to: question.id, by: DemoRoom.assistant, with: "👍", in: conversation)
            room.say("I will bring the garden notebook.", by: DemoRoom.assistant, in: conversation, replyTo: question.id)
            room.say("Everything is ready for the walk.", by: DemoRoom.person, in: conversation)
        }
    }
}
#endif
