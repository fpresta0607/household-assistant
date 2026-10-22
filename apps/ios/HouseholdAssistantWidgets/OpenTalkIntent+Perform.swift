// The Talk intent as the widget extension has it, so its Talk button and the Talk control
// can name it. It opens the app, and iOS performs it there (the app's
// OpenTalkIntent+Perform), so this one does nothing of its own.

import AppIntents

extension OpenTalkIntent {
    func perform() async throws -> some IntentResult {
        .result()
    }
}
