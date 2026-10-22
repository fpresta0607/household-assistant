// The only thing that crosses from the app to the widgets.
//
// A widget runs in its own process and cannot read the app's container, so the app
// writes what the widgets display, and only that, into the App Group's defaults: the
// assistant's name and emoji as the gateway reported them, who is in the family room,
// and each conversation's newest lines with how many are unread. No token and no host
// ever goes here. The faces are the ones the app already draws into the same group for
// the notifications (NotificationFaces).
//
// Compiled into the app, the widget extension and the Linux tests.

import Foundation

struct WidgetSnapshot: Codable, Equatable, Sendable {
    /// Somebody in the family room, as a widget draws their face.
    struct Face: Codable, Equatable, Sendable {
        let id: String
        let name: String
        let isAssistant: Bool
        /// True for the person this phone belongs to.
        let isOwner: Bool
        let emoji: String?
        /// Whether a photo was chosen for them, which the widgets read from the face the
        /// app draws for the notifications.
        let hasPhoto: Bool
        /// The ring an assistant's face is drawn in, when its person picked one: gold
        /// otherwise.
        var ring: RingColor? = nil
    }

    /// One message as a widget says it, in a line.
    struct Line: Codable, Equatable, Identifiable, Sendable {
        let id: String
        /// A participant id.
        let author: String
        /// The words, or what was sent when there are none, such as "Photo".
        let text: String
        /// The SF Symbol for what was sent, when there are no words.
        let symbol: String?
        let sentAt: Date
    }

    /// What the widgets show of one conversation.
    struct Conversation: Codable, Equatable, Sendable {
        /// The newest messages the gateway has kept, oldest first.
        var lines: [Line] = []
        var unread = 0
    }

    var assistantName: String?
    var assistantEmoji: String?
    /// This phone's person and their assistant, by participant id, once the room has said.
    var me: String?
    var assistant: String?
    /// Everyone in the family room, seated the way its circle of faces seats them.
    var faces: [Face] = []
    var family = Conversation()
    var direct = Conversation()

    /// Must match the `com.apple.security.application-groups` entitlement on
    /// both targets in `project.yml`.
    static let appGroup = "group.com.siqstack.stewardai"
    private static let key = "widget-snapshot"

    func conversation(_ conversation: RoomConversation) -> Conversation {
        conversation == .family ? family : direct
    }

    func face(_ id: String?) -> Face? {
        faces.first { $0.id == id }
    }

    static func load() -> WidgetSnapshot {
        guard
            let data = UserDefaults(suiteName: appGroup)?.data(forKey: key),
            let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
        else {
            return WidgetSnapshot()
        }
        return snapshot
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else {
            return
        }
        UserDefaults(suiteName: WidgetSnapshot.appGroup)?.set(data, forKey: WidgetSnapshot.key)
    }
}
