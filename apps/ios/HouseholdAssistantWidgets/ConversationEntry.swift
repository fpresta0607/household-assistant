// What a conversation's widget draws at one moment.

import UIKit
import WidgetKit

struct ConversationEntry: TimelineEntry {
    let date: Date
    let conversation: RoomConversation
    let snapshot: WidgetSnapshot
    /// The photo faces, by participant id (WidgetFacePhotos).
    let photos: [String: UIImage]
}
