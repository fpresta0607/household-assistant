// A segmented control whose chosen segment sits under a glass lens, which slides across
// to the next choice on a spring, or fades there with Reduce Motion. A name too long for
// its segment wraps onto a second line, or, where the control asks for one line, shrinks
// a little to keep the word whole.

import SwiftUI

struct GlassSegmentedControl<Choice: Hashable>: View {
    let choices: [Choice]
    @Binding var selection: Choice
    var isOneLine = false
    let label: (Choice) -> String

    @Environment(\.reducesMotion) private var reduceMotion
    @Namespace private var lens

    var body: some View {
        HStack(spacing: 0) {
            ForEach(choices, id: \.self) { choice in
                let isChosen = choice == selection
                Button {
                    withAnimation(Motion.flip(reduced: reduceMotion)) {
                        selection = choice
                    }
                } label: {
                    Text(label(choice))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(isOneLine ? 1 : nil)
                        .minimumScaleFactor(isOneLine ? 0.6 : 1)
                        .foregroundStyle(isChosen ? Palette.highlight : Palette.text)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background {
                            if isChosen {
                                Color.clear
                                    .liquidGlass(.regular.interactive(), in: Capsule())
                                    .matchedGeometryEffect(id: "lens", in: lens)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isChosen ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Palette.text.opacity(0.08), in: Capsule())
        .haptic(.selection, trigger: selection)
    }
}
