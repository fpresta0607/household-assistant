// Renaming this phone's assistant: up to 24 letters, spaces, hyphens and apostrophes, the
// rule its gateway holds a change to. Save waits until the name is one it will take, and
// the page goes back once the gateway has it.

import SwiftUI

struct NamePage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        let settings = model.assistantSettings
        let cleaned = AssistantName.cleaned(typed)
        let isUnchanged = cleaned == settings.current?.assistant.name
        SettingsPage("Name") {
            SettingsGroup(
                note: "Letters, spaces, hyphens and apostrophes, up to \(AssistantName.longest). The new name is used everywhere at once.",
                refusal: settings.refusal(for: [.name])
            ) {
                HStack(spacing: 12) {
                    TextField("Name", text: $typed)
                        .font(.body)
                        .foregroundStyle(Palette.text)
                        .textContentType(.name)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($isFocused)
                        .onSubmit(save)
                    if settings.isPending(.name) {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 50)
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(!AssistantName.isValid(cleaned) || isUnchanged || settings.isPending(.name))
            }
        }
        .onAppear {
            typed = settings.name ?? ""
            isFocused = true
        }
    }

    private func save() {
        let name = AssistantName.cleaned(typed)
        let settings = model.assistantSettings
        guard AssistantName.isValid(name), name != settings.current?.assistant.name else {
            return
        }
        Task {
            await settings.change(.name, to: name)
            if settings.refusal == nil {
                dismiss()
            }
        }
    }
}
