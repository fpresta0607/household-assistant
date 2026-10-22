// A voice note from outside the app: the microphone on a conversation's widget. It opens
// the app on that conversation already recording, locked, since no finger is holding it.
// A button with an intent, rather than a link, because the small widget has room for only
// one link, the one that opens the conversation.
//
// Compiled into the app and the widget extension both, like OpenTalkIntent, and iOS
// performs it in the app's process. Each target says what performing it does
// (OpenRecordingIntent+Perform).

import AppIntents

struct OpenRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Record a voice note"
    static let description = IntentDescription("Opens Steward AI straight into a voice note in one of its conversations.")
    static let openAppWhenRun = true
    /// Only the widget's microphone runs it, so Shortcuts does not offer it.
    static let isDiscoverable = false

    /// The conversation's raw value, `family` or `direct`.
    @Parameter(title: "Conversation")
    var conversation: String?

    init() {}

    init(conversation: RoomConversation) {
        self.conversation = conversation.rawValue
    }
}
