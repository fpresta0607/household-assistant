// The reply and the reactions a long press on a notification offers, registered once per
// conversation so the reply field says where the words go: to The Fam, or to the
// assistant by name. Each asks for the phone to be unlocked first, because what it sends
// speaks for this phone's person, signed by this phone.

import UserNotifications

enum NotificationCategories {
    static func register(assistantName: String) {
        let reactions = NotificationActions.reactions.map { emoji in
            UNNotificationAction(identifier: NotificationActions.reaction(emoji), title: emoji, options: [.authenticationRequired])
        }
        let categories = RoomConversation.allCases.map { conversation in
            let reply = UNTextInputNotificationAction(
                identifier: NotificationActions.reply,
                title: "Reply",
                options: [.authenticationRequired],
                icon: UNNotificationActionIcon(systemImageName: "arrowshape.turn.up.left"),
                textInputButtonTitle: "Send",
                textInputPlaceholder: "Reply to \(NotificationActions.name(of: conversation, assistantName: assistantName))"
            )
            let actions: [UNNotificationAction] = [reply] + reactions
            return UNNotificationCategory(
                identifier: NotificationActions.category(for: conversation),
                actions: actions,
                intentIdentifiers: [],
                options: []
            )
        }
        UNUserNotificationCenter.current().setNotificationCategories(Set(categories))
    }
}
