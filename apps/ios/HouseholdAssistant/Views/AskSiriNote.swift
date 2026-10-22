// How to reach the assistant without opening the app.

import SwiftUI

struct AskSiriNote: View {
    @Environment(AppModel.self) private var model

    /// The name Siri matches the shortcut phrase against: the assistant's own, when the app
    /// carries it as one of its alternative names (project.yml), or the app's.
    private var appName: String {
        let alternatives = (Bundle.main.object(forInfoDictionaryKey: "INAlternativeAppNames") as? [[String: Any]] ?? [])
            .compactMap { $0["INAlternativeAppName"] as? String }
        if alternatives.contains(model.assistantName) {
            return model.assistantName
        }
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "this app"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Say \u{201C}Hey Siri, ask \(appName)\u{201D}", systemImage: "waveform")
                .font(.subheadline.weight(.semibold))
            Text("Siri asks what you want to know, passes it to \(model.assistantName), and reads the answer back.")
                .font(.footnote)
                .foregroundStyle(Palette.secondaryText)
        }
        .padding(.vertical, 4)
    }
}
