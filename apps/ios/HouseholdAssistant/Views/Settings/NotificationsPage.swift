// Notifications: when this iPhone is told about each conversation, its own choice that
// changes nothing for anyone else and that its gateway's push follows, and how fast voice
// notes play, on a glass segmented control.
//
// Only when I am mentioned is offered for the family room, where other people talk. In
// this phone's own thread everything is its assistant talking to its person.
//
// Whatever is chosen here, iOS has the last word: with notifications off for Steward AI in
// the iPhone's Settings, or delivered quietly to Notification Center, the page says so first
// and opens Steward AI's page there, and reads it again on the way back (Permissions).

import SwiftUI

struct NotificationsPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.reducesMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var player = VoiceNotePlayer.shared

    var body: some View {
        let permissions = model.permissions
        let status = permissions.status(of: .notifications)
        SettingsPage("Notifications") {
            if status != .allowed || permissions.isDeliveredQuietly {
                SettingsGroup(note: iPhoneNote(status, isQuiet: permissions.isDeliveredQuietly)) {
                    SettingsRow("On this iPhone") {
                        RowValue(text: permissions.isDeliveredQuietly ? "Quiet" : status.label, opensPage: false)
                    }
                    if status == .notAsked {
                        Button {
                            Task {
                                await permissions.request(.notifications)
                            }
                        } label: {
                            SettingsRow("Allow notifications") {
                                Image(systemName: "bell.badge")
                                    .foregroundStyle(Palette.highlight)
                            }
                        }
                        .buttonStyle(.settingsRow)
                    } else {
                        OpenIPhoneSettingsRow()
                    }
                }
            }
            conversation(.family, titled: "The Fam", choices: NotificationChoice.allCases)
            conversation(.direct, titled: model.assistantName, choices: [.all, .off])
            SettingsGroup("Voice notes", note: "The speed every voice note starts at. The chip on a note changes it too.") {
                HStack(spacing: 12) {
                    Text("Playback speed")
                        .font(.body)
                        .foregroundStyle(Palette.text)
                    Spacer(minLength: 8)
                    GlassSegmentedControl(choices: PlaybackSpeed.allCases, selection: $player.speed) { $0.label }
                        .frame(width: 186)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 54)
            }
        }
        .task(id: model.connection.state == .connected) {
            await model.permissions.refresh()
            if model.connection.state == .connected {
                await model.assistantSettings.load()
            }
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

    /// What iOS lets through, whatever is chosen below.
    private func iPhoneNote(_ status: PermissionStatus, isQuiet: Bool) -> String {
        if isQuiet {
            return "iOS delivers Steward AI's notifications quietly, to Notification Center only, with no sound or banner. Change that in your iPhone's Settings."
        }
        switch status {
        case .notAsked:
            return "iOS has not been asked yet, so nothing below reaches you until you allow notifications."
        case .allowed, .denied:
            return "Notifications are off for Steward AI in your iPhone's Settings, so nothing below reaches you. Turn them on there."
        }
    }

    private func conversation(_ conversation: RoomConversation, titled title: String, choices: [NotificationChoice]) -> some View {
        let settings = model.assistantSettings
        let field = SettingsField.notifications(conversation)
        let chosen = settings.notificationChoice(in: conversation)
        return SettingsGroup(title, refusal: settings.refusal(for: [field])) {
            ForEach(choices, id: \.self) { choice in
                Button {
                    Task {
                        await settings.change(field, to: choice.rawValue)
                    }
                } label: {
                    SettingsRow(choice.label, subtitle: detail(of: choice)) {
                        if choice == chosen {
                            HStack(spacing: 8) {
                                if settings.isPending(field) {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Palette.highlight)
                            }
                        }
                    }
                }
                .buttonStyle(.settingsRow)
                .disabled(choice == chosen || settings.current == nil)
                .accessibilityAddTraits(choice == chosen ? .isSelected : [])
            }
        }
        .animation(Motion.flip(reduced: reduceMotion), value: chosen)
    }

    private func detail(of choice: NotificationChoice) -> String {
        switch choice {
        case .all:
            return "Every message"
        case .mentions:
            return "Only when you or \(model.assistantName) are named"
        case .off:
            return "Nothing from here"
        }
    }
}
