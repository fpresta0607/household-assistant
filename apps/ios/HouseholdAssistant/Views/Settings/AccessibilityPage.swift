// Accessibility: Reduce Motion and text size, like the iPhone's or set here, bold text,
// haptics, transcripts under voice notes, and whether Talk reads replies aloud. All of it
// stays on this phone. Every animation in the app follows Reduce Motion through `Motion`,
// and every haptic goes through `haptic`, so these switches cover all of them.
//
// What follows the iPhone says what the iPhone has, and Bold Text on in the iPhone's own
// Settings bolds the app whatever its switch says, so the switch shows it on and opens
// Steward AI's page there, read again on the way back (Permissions).

import SwiftUI

struct AccessibilityPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.reducesMotion) private var reduceMotion
    @Environment(\.accessibilityReduceMotion) private var isReducedOnIPhone
    /// The iPhone's own size while text size is Like iPhone, which is when it is shown.
    @Environment(\.dynamicTypeSize) private var textSizeOnIPhone
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var settings = model.settings
        let isTextBoldOnIPhone = model.permissions.isTextBoldOnIPhone
        SettingsPage("Accessibility") {
            SettingsGroup(note: "Reduce Motion and text size follow your iPhone unless you set them here.") {
                NavigationLink {
                    ChoicePage(
                        title: "Reduce Motion",
                        choices: ReduceMotionChoice.allCases,
                        selection: settings.reduceMotion,
                        note: "With it on, bubbles, switches and lifts fade into place instead of springing.",
                        label: { $0.label }
                    ) { choice in
                        model.settings.reduceMotion = choice
                    }
                } label: {
                    SettingsRow("Reduce Motion", subtitle: "Fades instead of springs and lifts") {
                        RowValue(text: settings.reduceMotion == .likeIPhone
                            ? "Like iPhone, \(isReducedOnIPhone ? "On" : "Off")"
                            : settings.reduceMotion.label)
                    }
                }
                .buttonStyle(.settingsRow)
                NavigationLink {
                    TextSizePage()
                } label: {
                    SettingsRow("Text size", subtitle: settings.textSize == .likeIPhone ? "Like iPhone" : nil) {
                        RowValue(text: settings.textSize == .likeIPhone
                            ? TextSizeChoice.label(ofIPhone: textSizeOnIPhone)
                            : settings.textSize.label)
                    }
                }
                .buttonStyle(.settingsRow)
                SettingsRow("Bold text", subtitle: isTextBoldOnIPhone ? "On in iPhone Settings" : nil) {
                    Toggle(
                        "Bold text",
                        isOn: Binding {
                            settings.isTextBold || isTextBoldOnIPhone
                        } set: { isOn in
                            withAnimation(Motion.flip(reduced: reduceMotion)) {
                                settings.isTextBold = isOn
                            }
                        }
                    )
                    .labelsHidden()
                    .tint(Palette.highlight)
                    .disabled(isTextBoldOnIPhone)
                }
                if isTextBoldOnIPhone {
                    OpenIPhoneSettingsRow()
                }
                toggle("Haptics", isOn: $settings.isHapticsOn)
                toggle("Transcripts under voice notes", isOn: $settings.shouldShowTranscripts)
                toggle("Read replies aloud on calls", isOn: $settings.shouldReadRepliesAloud)
            }
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

    /// A switch that flips on a spring.
    private func toggle(_ title: String, isOn: Binding<Bool>) -> some View {
        SettingsRow(title) {
            Toggle(title, isOn: isOn.animation(Motion.flip(reduced: reduceMotion)))
                .labelsHidden()
                .tint(Palette.highlight)
        }
    }
}
