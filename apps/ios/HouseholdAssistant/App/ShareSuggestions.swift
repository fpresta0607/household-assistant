// One Steward AI in the Share Sheet's top row: this phone's own assistant, with its face,
// Corey on Franco's iPhone and Denise on Gia's. iOS suggests the conversations a person sends
// to, from the messages an app tells it about, so every message the person sends their
// assistant is donated as an outgoing INSendMessageIntent naming that thread, with the face
// the app already draws into the App Group for the notifications (NotificationFaces).
// Picking it opens the Share Extension on that thread, where the family room is still a
// choice. The family room is no suggestion of its own: the owner wanted one Steward AI
// there, so what builds before this one donated for it is taken back.

import Intents
import UIKit

@MainActor
enum ShareSuggestions {
    /// Tells iOS the person sent a message in `conversation`, when it is their own thread.
    static func donate(_ conversation: RoomConversation, participants: [RoomParticipant], me: RoomSelf) {
        guard conversation == .direct else {
            return
        }
        INInteraction.delete(with: RoomConversation.family.rawValue, completion: nil)
        let others = participants.filter { $0.id == me.assistant }
        let recipients = others.map { participant in
            INPerson(
                personHandle: INPersonHandle(value: participant.id, type: .unknown),
                nameComponents: nil,
                displayName: participant.name,
                image: face(of: participant.id),
                contactIdentifier: nil,
                customIdentifier: participant.id
            )
        }
        let intent = INSendMessageIntent(
            recipients: recipients,
            outgoingMessageType: .outgoingMessageText,
            content: nil,
            speakableGroupName: nil,
            conversationIdentifier: conversation.rawValue,
            serviceName: nil,
            sender: nil,
            attachments: nil
        )
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .outgoing
        interaction.groupIdentifier = conversation.rawValue
        interaction.donate(completion: nil)
    }

    /// The conversations of a gateway this phone no longer pairs with are no suggestion.
    static func forget() {
        INInteraction.deleteAll(completion: nil)
    }

    private static func face(of id: String) -> INImage? {
        guard
            let folder = NotificationFolder.url,
            let file = NotificationPeople.faceFile(for: id),
            let png = try? Data(contentsOf: folder.appendingPathComponent(file))
        else {
            return nil
        }
        return INImage(imageData: png)
    }
}
