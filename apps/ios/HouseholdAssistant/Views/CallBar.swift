// The slim bar over the app while a call goes on with its screen left, as the green bar is
// on an iPhone call: the assistant's face with the gold ring that follows the voice, its
// name, and the time, or what the call is doing. A tap brings the call's screen back. What
// is below moves down to make room rather than going under it, and the bar taps as the
// call moves, as the call's screen does. Glass with its phone glyph in the microphone's
// colour, like the Call button.
//
// A value in, a picture out: Chats feeds it the live call, and the screenshot test feeds
// it a call by hand.

import SwiftUI

struct CallBar: View {
    let state: CallState
    /// 0...1, already smoothed.
    let level: Double
    let onTap: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.reducesMotion) private var reduceMotion

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                AssistantAvatar(emoji: model.identity?.emoji, photo: model.assistantPhoto, size: 28, ring: model.assistantRing)
                    .background {
                        Circle()
                            .stroke(model.assistantRing.ringColor.opacity(0.2 + 0.6 * level), lineWidth: 2)
                            .scaleEffect(reduceMotion ? 1.18 : 1.18 + 0.12 * level)
                    }
                Text(model.assistantName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                TimelineView(.periodic(from: state.connectedAt ?? .now, by: 1)) { context in
                    Text(state.barWords(at: context.date))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(1)
                }
                Image(systemName: "phone.fill")
                    .font(.subheadline)
                    .foregroundStyle(Palette.highlight)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .rainbowGlass(in: Capsule(), isInteractive: true)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Back to the call with \(model.assistantName)")
        .accessibilityValue(state.barWords(at: .now))
        .accessibilityAddTraits(.isButton)
        .callStageHaptic(state.stage)
    }
}

extension View {
    /// `bar` over the top of everything below it, which moves down to make room, as it does
    /// for the green bar on an iPhone call. With no bar, nothing.
    func callBar(_ bar: CallBar?) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            if let bar {
                bar
            }
        }
    }
}
