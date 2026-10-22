// Text size, from Accessibility: like the iPhone's own setting, or a size of its own for
// this app, chosen on a slider from the smallest to the largest standard size, with a line
// that shows it as it changes. Its own size starts at the iPhone's, so turning Like iPhone
// off changes nothing until the slider moves.

import SwiftUI

struct TextSizePage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.reducesMotion) private var reduceMotion
    /// The iPhone's own size while Like iPhone is on, which is when it is read.
    @Environment(\.dynamicTypeSize) private var textSizeOnIPhone

    var body: some View {
        let settings = model.settings
        let sizes = TextSizeChoice.sizes
        let isLikeIPhone = Binding(
            get: { settings.textSize == .likeIPhone },
            set: { isOn in
                settings.textSize = isOn ? .likeIPhone : TextSizeChoice(nearest: textSizeOnIPhone)
            }
        )
        let step = Binding(
            get: { Double(sizes.firstIndex(of: settings.textSize) ?? sizes.firstIndex(of: .large) ?? 0) },
            set: { index in
                settings.textSize = sizes[min(max(Int(index.rounded()), 0), sizes.count - 1)]
            }
        )
        SettingsPage("Text size") {
            SettingsGroup {
                SettingsRow(
                    "Like iPhone",
                    subtitle: settings.textSize == .likeIPhone
                        ? "\(TextSizeChoice.label(ofIPhone: textSizeOnIPhone)), from Display and Text Size in iOS Settings"
                        : "Follows Display and Text Size in iOS Settings"
                ) {
                    Toggle("Like iPhone", isOn: isLikeIPhone.animation(Motion.flip(reduced: reduceMotion)))
                        .labelsHidden()
                        .tint(Palette.highlight)
                }
            }
            if settings.textSize != .likeIPhone {
                SettingsGroup(note: settings.textSize.label) {
                    HStack(spacing: 12) {
                        Text("A")
                            .font(.footnote)
                        Slider(value: step, in: 0...Double(sizes.count - 1), step: 1)
                            .tint(Palette.highlight)
                            .accessibilityLabel("Text size")
                            .accessibilityValue(settings.textSize.label)
                        Text("A")
                            .font(.title2)
                    }
                    .foregroundStyle(Palette.text)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    Text("\(model.assistantName) will remind you at 5:30 PM to leave for soccer.")
                        .font(.body)
                        .foregroundStyle(Palette.text)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityHidden(true)
                }
                .transition(.opacity)
            }
        }
    }
}
