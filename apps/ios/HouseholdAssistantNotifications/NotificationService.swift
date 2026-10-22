// Shows who said what in a notification Apple delivered as only "New message", as a
// message from whoever wrote it: their face and name, the family room's name over a
// family message, stacked by conversation.
//
// Runs for every notification marked mutable and opens the sealed part with this phone's
// key. Then it hands iOS the message as an incoming INSendMessageIntent, which is what
// turns on the communication style with the sender's face. The faces and who is who are
// what the app drew into the App Group (NotificationFaces). Anything that does not open
// leaves the plain alert, which still says there is a new message, and a missing face
// leaves the name.

import Intents
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        guard
            let content = request.content.mutableCopy() as? UNMutableNotificationContent,
            let sealed = request.content.userInfo["e"] as? String,
            let opened = PushKey.open(sealed)
        else {
            contentHandler(request.content)
            return
        }
        content.title = opened.title
        content.body = opened.body
        content.threadIdentifier = opened.conversation.rawValue
        for (key, value) in opened.userInfo {
            content.userInfo[key] = value
        }
        let intent = Self.message(opened)
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        // Without the Communication Notifications capability iOS refuses the update, and
        // the name and the words still show.
        interaction.donate { _ in
            contentHandler((try? content.updating(from: intent)) ?? content)
        }
    }

    private static func message(_ opened: NotificationPayload) -> INSendMessageIntent {
        let folder = NotificationFolder.url
        let people = folder
            .flatMap { try? Data(contentsOf: $0.appendingPathComponent(NotificationPeople.file)) }
            .flatMap { try? JSONDecoder().decode(NotificationPeople.self, from: $0) }
        let face = NotificationPeople.faceFile(for: opened.sender).flatMap { file in
            folder.flatMap { try? Data(contentsOf: $0.appendingPathComponent(file)) }
        }
        let recipients = people.map { known in
            known.recipients(of: opened.sender, in: opened.conversation).map { id in
                person(id, name: known.names[id] ?? id, isMe: id == known.me)
            }
        }
        return INSendMessageIntent(
            recipients: recipients,
            outgoingMessageType: .outgoingMessageText,
            content: opened.body,
            speakableGroupName: opened.groupName.map { INSpeakableString(spokenPhrase: $0) },
            conversationIdentifier: opened.conversation.rawValue,
            serviceName: nil,
            sender: person(opened.sender, name: opened.title, face: face),
            attachments: nil
        )
    }

    private static func person(_ id: String, name: String, isMe: Bool = false, face: Data? = nil) -> INPerson {
        INPerson(
            personHandle: INPersonHandle(value: id, type: .unknown),
            nameComponents: nil,
            displayName: name,
            image: face.map { INImage(imageData: $0) },
            contactIdentifier: nil,
            customIdentifier: id,
            isMe: isMe,
            suggestionType: .none
        )
    }
}
