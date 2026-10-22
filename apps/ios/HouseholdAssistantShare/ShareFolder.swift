// Where the Share Extension leaves what was shared for the app: the outbox in the App
// Group both share (ShareOutbox), and the Darwin notification that tells a running app
// something is waiting there.

import Foundation

enum ShareFolder {
    /// Posted by the extension once a hand-off is ready, and heard by the app while it runs.
    static let posted = "com.siqstack.stewardai.share.posted"

    static var outbox: ShareOutbox? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WidgetSnapshot.appGroup)
            .map { ShareOutbox(folder: $0.appendingPathComponent("outbox", isDirectory: true)) }
    }

    /// Tells the app a hand-off is ready. An app that is not running hears nothing, and
    /// finds it when it next comes to the front.
    static func announce() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(posted as CFString),
            nil,
            nil,
            true
        )
    }
}
