// Where the app leaves what the notification extension shows beside the words: the faces
// it draws and who is who (NotificationPeople), in the App Group both share.

import Foundation

enum NotificationFolder {
    static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: PushKey.accessGroup)?
            .appendingPathComponent("notifications", isDirectory: true)
    }
}
