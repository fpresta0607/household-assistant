// Who is in the app's conversations, for the notification extension, which runs in its
// own process with no link to the gateway: each participant's name, and which of them
// are this phone's person and their assistant. The app writes it into the App Group with
// the faces it draws (NotificationFaces) whenever the room's participants change.

import Foundation

struct NotificationPeople: Codable, Equatable, Sendable {
    /// This phone's person.
    let me: String
    /// Their assistant.
    let assistant: String
    /// Everyone in the family room, by id.
    let names: [String: String]

    /// Its file in the folder the app and the extension share (NotificationFolder).
    static let file = "people.json"
    private static let faceFileCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")

    /// Who else a message in `conversation` went to: the rest of the family room, or in
    /// this phone's own thread, the other of its two.
    func recipients(of sender: String, in conversation: RoomConversation) -> [String] {
        let members = conversation == .family ? names.keys.sorted() : [me, assistant]
        return members.filter { $0 != sender }
    }

    /// The file a participant's face is drawn in, or nil for an id that could name
    /// anything but a file of its own.
    static func faceFile(for id: String) -> String? {
        guard (1...64).contains(id.count), id.allSatisfy(faceFileCharacters.contains) else {
            return nil
        }
        return id + ".png"
    }
}
