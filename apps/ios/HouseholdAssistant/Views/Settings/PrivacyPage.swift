// Privacy: App Lock, which opens Steward AI only for Face ID or this iPhone's passcode, on
// every fresh open and again after the time chosen in the background. It stays on this
// phone and tells nobody anything. Contacts is a connector now (ContactsConnectorPage).
//
// Require Face ID turns on only once Face ID or the passcode passes, so iOS asks whether
// Steward AI may use Face ID here rather than as the app next opens. Off needs nothing.
//
// It mirrors the iPhone (Permissions): the lock is named for what this iPhone opens with,
// Face ID, Touch ID, Optic ID or the passcode, and the switch never says On when iOS will
// not let it work. Where only iOS can change that, the group says so and opens Steward
// AI's page in the iPhone's Settings, and the page reads it again on the way back.

import SwiftUI

struct PrivacyPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.reducesMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    /// Why Require Face ID did not turn on, until the switch is touched again.
    @State private var lockRefusal: String?

    var body: some View {
        @Bindable var settings = model.settings
        let permissions = model.permissions
        let lockName = permissions.lockName
        let lock = permissions.state(of: .faceID)
        let isLockOn = settings.isAppLockOn && lock != .unavailable
        SettingsPage("Privacy") {
            SettingsGroup(
                "App Lock",
                note: Self.lockNote(lockName: lockName, lock: lock),
                refusal: lockRefusal
            ) {
                SettingsRow("Require \(lockName)") {
                    Toggle("Require \(lockName)", isOn: Binding { isLockOn } set: { isOn in requireFaceID(isOn) })
                        .labelsHidden()
                        .tint(Palette.highlight)
                        .disabled(model.cover.isChecking || lock == .unavailable)
                }
                if lock.isUpToIOS {
                    OpenIPhoneSettingsRow()
                }
                if isLockOn {
                    NavigationLink {
                        ChoicePage(
                            title: "Ask again",
                            choices: AppLockTiming.allCases,
                            selection: settings.appLockTiming,
                            note: "How long Steward AI can be away before it asks for Face ID again. Opening it afresh always asks.",
                            label: { $0.label }
                        ) { timing in
                            model.settings.appLockTiming = timing
                        }
                    } label: {
                        SettingsRow("Ask again") {
                            RowValue(text: settings.appLockTiming.label)
                        }
                    }
                    .buttonStyle(.settingsRow)
                    .transition(.opacity)
                }
            }
            .animation(Motion.flip(reduced: reduceMotion), value: settings.isAppLockOn)
        }
        .task {
            await model.permissions.refresh()
        }
        .onChange(of: scenePhase) { _, phase in
            // Back from the iPhone's Settings: show what changed there.
            if phase == .active {
                Task {
                    await model.permissions.refresh()
                }
            }
        }
    }

    /// What App Lock does on this iPhone, and when only iOS can make it work.
    private static func lockNote(lockName: String, lock: PhoneAccessState) -> String {
        switch lock {
        case .unavailable:
            return "This iPhone has no passcode, so App Lock has nothing to ask for. Set one up in your iPhone's Settings first."
        case .denied:
            return "\(lockName) is off for Steward AI in your iPhone's Settings, so App Lock asks for your passcode instead. Turn it on there to use \(lockName)."
        case .notAsked, .allowed, .limited:
            let isPasscodeOnly = lockName == "Passcode"
            let fallback = isPasscodeOnly ? "" : " Your passcode works when \(lockName) cannot."
            return "Steward AI asks for \(isPasscodeOnly ? "your passcode" : lockName) each time it opens, and again after it has been away for the time you choose.\(fallback)"
        }
    }

    private func requireFaceID(_ isOn: Bool) {
        lockRefusal = nil
        guard isOn else {
            model.settings.isAppLockOn = false
            return
        }
        Task {
            if await model.cover.requireFaceID() == .unavailable {
                lockRefusal = "Set a passcode for this iPhone in its Settings first, then App Lock can use Face ID."
            }
        }
    }
}
