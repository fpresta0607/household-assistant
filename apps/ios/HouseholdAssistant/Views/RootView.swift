// Chats is home, each conversation opens over it, and Settings is the glass tab bar's
// other tab, which your own face on Chats opens too. Until the phone is paired and has
// been offered what is worth turning on, the onboarding stands in for all of it.
// Whatever Appearance and Accessibility set applies from here down.

import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.isPaired && model.settings.hasOfferedPermissions {
                InboxView()
                    .transition(.opacity)
            } else {
                OnboardingView()
                    .transition(.opacity)
            }
        }
        .tint(Palette.highlight)
        .phonePreferences(model.settings)
        .animation(Motion.fade, value: model.isPaired && model.settings.hasOfferedPermissions)
        .alert(
            "Move this phone?",
            isPresented: Binding(
                get: { model.pendingPairingCode != nil },
                set: { isShown in
                    if !isShown {
                        model.pendingPairingCode = nil
                    }
                }
            ),
            presenting: model.pendingPairingCode
        ) { code in
            Button("Pair") {
                model.pair(code)
            }
            Button("Cancel", role: .cancel) {
                model.pendingPairingCode = nil
            }
        } message: { code in
            Text("This phone will pair with \(code.assistant ?? "a new assistant") instead of \(model.assistantName).")
        }
    }
}
