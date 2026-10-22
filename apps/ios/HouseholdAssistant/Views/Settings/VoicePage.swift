// The voices this phone's assistant can speak in, each with its sample: play one to hear
// it, tap one to choose it. The check moves once the gateway has made the change.

import SwiftUI

struct VoicePage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.reducesMotion) private var reduceMotion

    var body: some View {
        let settings = model.assistantSettings
        let name = model.assistantName
        let words = AssistantPage.sampleWords(name)
        SettingsPage("\(name)'s voice") {
            SettingsGroup(
                note: "Each sample is spoken by \(name)'s gateway in that voice.",
                refusal: settings.refusal(for: [.voice]) ?? settings.sampleRefusal
            ) {
                ForEach(settings.current?.voices ?? []) { voice in
                    let isChosen = voice.id == settings.voice?.id
                    HStack(spacing: 0) {
                        VoiceSampleButton(voice: voice.id, words: words, voiceName: voice.name)
                            .padding(.leading, 16)
                        Button {
                            Task {
                                await settings.change(.voice, to: voice.id)
                            }
                        } label: {
                            SettingsRow(voice.name, subtitle: voice.summary) {
                                HStack(spacing: 8) {
                                    if isChosen && settings.isPending(.voice) {
                                        ProgressView()
                                            .controlSize(.small)
                                    }
                                    if isChosen {
                                        Image(systemName: "checkmark")
                                            .font(.body.weight(.semibold))
                                            .foregroundStyle(Palette.highlight)
                                    }
                                }
                            }
                        }
                        .buttonStyle(.settingsRow)
                        .disabled(isChosen)
                        .accessibilityAddTraits(isChosen ? .isSelected : [])
                    }
                }
            }
            .animation(Motion.flip(reduced: reduceMotion), value: settings.voice?.id)
        }
    }
}
