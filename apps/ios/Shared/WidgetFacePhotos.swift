// The faces the widgets show for everyone who has a photo: the ones the app draws into
// the App Group for the notifications (NotificationFaces), read back as they are.

import Foundation
import UIKit

enum WidgetFacePhotos {
    /// NotificationFolder's folder. That file takes the App Group's name from the push
    /// key, which the widget extension has no use for, so it is named here again and a
    /// test holds the two together.
    static var folder: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WidgetSnapshot.appGroup)?
            .appendingPathComponent("notifications", isDirectory: true)
    }

    /// Each photo face by participant id. One the app has not drawn yet is left out, and
    /// the widget draws that face as the app does without a photo.
    static func load(for snapshot: WidgetSnapshot) -> [String: UIImage] {
        guard let folder else {
            return [:]
        }
        var photos: [String: UIImage] = [:]
        for face in snapshot.faces where face.hasPhoto {
            guard
                let file = NotificationPeople.faceFile(for: face.id),
                let photo = UIImage(contentsOfFile: folder.appendingPathComponent(file).path)
            else {
                continue
            }
            photos[face.id] = photo
        }
        return photos
    }
}
