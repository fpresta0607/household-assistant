// A quiet inline row after selecting a result and dismissing the keyboard. It has no
// separate glass toolbar. The count reopens the list; the arrows move through matches.

import SwiftUI

struct ThreadSearchSteps: View {
    let search: ThreadSearchModel
    let onStep: (_ isOlder: Bool) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button {
                search.isListShown = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "list.bullet")
                    Text(search.position)
                        .monospacedDigit()
                        .accessibilityIdentifier("search.position")
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Show all results")
            .accessibilityValue(search.position)
            .accessibilityIdentifier("search.list")
            Spacer(minLength: 0)
            Button { onStep(true) } label: {
                Image(systemName: "chevron.up")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(!canStep(isOlder: true))
            .accessibilityLabel("Older match")
            .accessibilityIdentifier("search.older")
            Button { onStep(false) } label: {
                Image(systemName: "chevron.down")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(!canStep(isOlder: false))
            .accessibilityLabel("Newer match")
            .accessibilityIdentifier("search.newer")
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(Palette.highlight)
        .buttonStyle(.plain)
        .padding(.leading, 52)
    }

    private func canStep(isOlder: Bool) -> Bool {
        guard search.isReady,
              let next = ThreadSearch.step(from: search.current, isOlder: isOlder, in: search.matches) else {
            return false
        }
        return next != search.current
    }
}

