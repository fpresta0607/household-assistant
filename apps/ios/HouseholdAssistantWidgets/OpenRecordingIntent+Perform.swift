// The voice note intent as the widget extension has it, so the widget's microphone can
// name it. It opens the app, and iOS performs it there (the app's
// OpenRecordingIntent+Perform), so this one does nothing of its own.

import AppIntents

extension OpenRecordingIntent {
    func perform() async throws -> some IntentResult {
        .result()
    }
}
