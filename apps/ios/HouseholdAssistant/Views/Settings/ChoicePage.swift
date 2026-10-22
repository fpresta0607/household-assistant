// A page of choices, one chosen, with a check by it and a spinner beside it while the
// choice is on its way to the gateway: how long the answers are, and Reduce Motion.

import SwiftUI

struct ChoicePage<Choice: Hashable>: View {
    let title: String
    let choices: [Choice]
    let selection: Choice?
    var isPending = false
    var note: String?
    var refusal: String?
    let label: (Choice) -> String
    let onPick: (Choice) -> Void

    @Environment(\.reducesMotion) private var reduceMotion

    var body: some View {
        SettingsPage(title) {
            SettingsGroup(note: note, refusal: refusal) {
                ForEach(choices, id: \.self) { choice in
                    Button {
                        onPick(choice)
                    } label: {
                        SettingsRow(label(choice)) {
                            if choice == selection {
                                HStack(spacing: 8) {
                                    if isPending {
                                        ProgressView()
                                            .controlSize(.small)
                                    }
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(Palette.highlight)
                                }
                                .transition(.opacity)
                            }
                        }
                    }
                    .buttonStyle(.settingsRow)
                    .accessibilityAddTraits(choice == selection ? .isSelected : [])
                }
            }
            .animation(Motion.flip(reduced: reduceMotion), value: selection)
        }
    }
}
