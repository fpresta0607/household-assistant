// A noninteractive sample using the app's own bubbles, rims, background and glass.
// The selected theme is previewed in the current appearance.

import SwiftUI

struct AppearancePreview: View {
    @Environment(AppModel.self) private var model
    let scheme: ColorScheme

    var body: some View {
        chat
            .environment(\.colorScheme, scheme)
            .environment(\.rims, RimLook(theme: model.settings.theme))
    }

    private var chat: some View {
        VStack(spacing: 10) {
            header
            VStack(spacing: 6) {
                bubble("Are we free Friday night?", isOwn: true)
                bubble("You are. Movie night is on the family calendar for 7.", isOwn: false)
                bubble("Perfect, thank you", isOwn: true)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            composer
            tabBar
        }
        .padding(12)
        .dynamicTypeSize(...DynamicTypeSize.large)
        .frame(height: 330)
        .background {
            MeshBackground()
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Palette.text.opacity(0.1), lineWidth: 0.5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sample chat in \(model.settings.theme.name), \(scheme == .dark ? "Dark" : "Light")")
        .accessibilityIdentifier("appearance.preview.\(scheme == .dark ? "dark" : "light")")
    }

    private var header: some View {
        VStack(spacing: 1) {
            AssistantAvatar(emoji: model.identity?.emoji, photo: model.assistantPhoto, size: 27, ring: model.assistantRing)
            HStack(spacing: 2) {
                Text(model.assistantName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                Image(systemName: "chevron.forward")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Palette.secondaryText)
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .padding(.vertical, 2)
            .rainbowGlass(in: Capsule())
        }
    }

    /// A bubble as the chat draws one: the person's own on the right in their colour, the
    /// assistant's on the left in its fill and rim, in the scheme a colour picked for it
    /// reads in.
    private func bubble(_ words: String, isOwn: Bool) -> some View {
        let shape = BubbleShape(isTrailing: isOwn, hasTail: true)
        return Text(words)
            .font(.footnote)
            .foregroundStyle(isOwn ? Palette.userBubbleText : Palette.assistantBubbleText)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background {
                shape
                    .fill(isOwn ? AnyShapeStyle(Palette.userBubbleFill) : AnyShapeStyle(Palette.assistantBubble))
                    .shadow(color: isOwn ? Palette.userBubble.opacity(0.22) : Palette.assistantShadow, radius: 5, y: 3)
            }
            .overlay {
                if !isOwn {
                    AssistantRim(shape: shape)
                }
            }
            .frame(maxWidth: 240, alignment: isOwn ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: isOwn ? .trailing : .leading)
    }

    private var composer: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.body.weight(.medium))
                .foregroundStyle(Palette.text)
                .frame(width: 34, height: 34)
                .liquidGlass(.regular, in: Circle())
            HStack {
                Text("Message")
                Spacer(minLength: 0)
                Image(systemName: "camera.fill")
            }
            .font(.footnote)
            .foregroundStyle(Palette.secondaryText)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .liquidGlass(.regular, in: Capsule())
            Image(systemName: "mic.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Palette.highlight)
                .frame(width: 40, height: 40)
                .liquidGlass(.regular, in: Circle())
                .overlay {
                    Circle().strokeBorder(Palette.highlight.opacity(0.55), lineWidth: 1.5)
                }
        }
    }

    /// A noninteractive sample of the native tab bar.
    private var tabBar: some View {
        HStack(spacing: 4) {
            tab("Chats", systemImage: "bubble.left.and.bubble.right.fill", isChosen: true)
            tab("Settings", systemImage: "gearshape.fill", isChosen: false)
        }
        .padding(4)
        .liquidGlass(.regular, in: Capsule())
    }

    private func tab(_ title: String, systemImage: String, isChosen: Bool) -> some View {
        VStack(spacing: 1) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
            Text(title)
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(isChosen ? Palette.highlight : Palette.text)
        .frame(width: 64, height: 34)
        .background {
            if isChosen {
                Capsule().fill(Palette.text.opacity(0.08))
            }
        }
    }
}

