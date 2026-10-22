// The widget bundle: a conversation on the Home Screen or the Lock Screen, the Lock
// Screen's Talk button, and the Talk control for Control Center, the Lock Screen and the
// Action button.

import SwiftUI
import WidgetKit

@main
struct HouseholdAssistantWidgets: WidgetBundle {
    var body: some Widget {
        ConversationWidget()
        TalkWidget()
        TalkControl()
    }
}
