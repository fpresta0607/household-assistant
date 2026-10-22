// A voice note, opened from a widget's microphone. iOS has opened the app for it, maybe
// from nothing, and the conversation's composer starts recording as it comes up.

import AppIntents

extension OpenRecordingIntent {
    @MainActor
    func perform() async throws -> some IntentResult {
        if let conversation = conversation.flatMap(RoomConversation.init(rawValue:)) {
            AppModel.shared.open(.record(conversation))
        }
        return .result()
    }
}
