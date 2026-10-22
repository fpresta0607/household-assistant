// Talk, opened from a widget's Talk button or the Talk control. iOS has opened the app
// for it, maybe from nothing, and Talk starts listening as it comes up.

import AppIntents

extension OpenTalkIntent {
    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.open(.talk)
        return .result()
    }
}
