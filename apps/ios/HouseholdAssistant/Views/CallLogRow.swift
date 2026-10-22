// A call with the assistant in its thread, once it ended: one quiet row in the middle, as
// a call shows in Messages, saying who, how long and when. Tapping it opens what was said.

import SwiftUI

struct CallLogRow: View {
    let call: RoomCall
    let assistantName: String
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Image(systemName: "phone.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.goldText)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Call with \(assistantName)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.text)
                    Text("\(call.length), \(call.startedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Palette.secondaryText)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.secondaryText)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Palette.secondaryText.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Call with \(assistantName), \(call.length), at \(call.startedAt.formatted(date: .omitted, time: .shortened))")
        .accessibilityHint("Opens what was said")
    }
}
