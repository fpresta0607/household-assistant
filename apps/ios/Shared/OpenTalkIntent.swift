// Hands-free Talk from outside the app: the Talk button on a widget, and the Talk control
// in Control Center, on the Lock Screen or on the Action button. It opens the app, which
// starts listening.
//
// Compiled into the app and the widget extension both. iOS performs an intent that opens
// the app in the app's own process when the app has it too, and that is where Talk is.
// Each target says what performing it does (OpenTalkIntent+Perform).

import AppIntents

struct OpenTalkIntent: AppIntent {
    static let title: LocalizedStringResource = "Call your assistant"
    static let description = IntentDescription("Opens Steward AI straight into a call with your assistant.")
    static let openAppWhenRun = true
}
