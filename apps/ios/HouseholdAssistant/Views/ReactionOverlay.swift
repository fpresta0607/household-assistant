// The iMessage lift: a long-pressed message rises out of the blurred thread, with the
// reaction bar above it and a short menu below. The bar holds the five tapbacks Messages
// has, the same five the assistants react with (Tapback), then a plus that opens the
// emoji keyboard, as Messages does, so any emoji can be a reaction. The emoji picked there
// reacts as a tapback does and puts the message down. Another emoji this phone already
// reacted with sits before the plus. Tapping the one this phone already chose takes it
// back; tapping anywhere else puts the message down.
//
// The menu replies, copies the words, and shares the message: its words, or its photos,
// videos, voice notes and files with the words beside them. An assistant's cards are
// copied and shared as plain lines (MessagePlainText). In the family room it can also ask
// this phone's assistant about the message, its sparkle in gold.
//
// The thread is blurred by the room; this draws what floats over it. The message is
// drawn again exactly where it sits, whole from the first frame, and never moves, however
// long it is, so the thread is just where it was when the menu closes. The bar and the
// menu open beside where the finger pressed, above it when there is room for both and
// below it when not, and always on screen.

import SwiftUI
import UIKit

// File-scope, not static members: a generic type cannot store a static.
private let reactionBarHeight: CGFloat = 56
private let reactionGap: CGFloat = 12
/// How far the bar and the menu keep from the finger, so it does not cover them.
private let fingerClearance: CGFloat = 28

struct ReactionOverlay<Lifted: View>: View {
    let message: RoomMessage
    /// Where the message's row was on screen when it was pressed.
    let rowFrame: CGRect
    /// Where the finger pressed, on screen; nil when VoiceOver lifted it.
    let pressPoint: CGPoint?
    let isOwn: Bool
    /// The message's copy is over the thread, so its row can give way to it.
    let onShown: () -> Void
    let onReact: (String) -> Void
    let onReply: () -> Void
    /// Asks this phone's assistant about the message; nil where the menu does not offer it.
    let onAsk: (() -> Void)?
    let onDismiss: () -> Void
    let lifted: Lifted

    @Environment(AppModel.self) private var model
    @Environment(\.reducesMotion) private var reduceMotion
    @State private var isLifted = false
    /// Whether the emoji keyboard is up for a reaction with any emoji.
    @State private var isPickingEmoji = false
    /// The message's attachments as files to share, once they are read.
    @State private var files: [URL]?
    @State private var hasFilesFailed = false
    /// A menu row is a finger tall, and taller with the text, so no size of it is clipped.
    @ScaledMetric(relativeTo: .body) private var menuRowHeight: CGFloat = 44

    init(
        message: RoomMessage,
        rowFrame: CGRect,
        pressPoint: CGPoint?,
        isOwn: Bool,
        onShown: @escaping () -> Void,
        onReact: @escaping (String) -> Void,
        onReply: @escaping () -> Void,
        onAsk: (() -> Void)?,
        onDismiss: @escaping () -> Void,
        @ViewBuilder lifted: () -> Lifted
    ) {
        self.message = message
        self.rowFrame = rowFrame
        self.pressPoint = pressPoint
        self.isOwn = isOwn
        self.onShown = onShown
        self.onReact = onReact
        self.onReply = onReply
        self.onAsk = onAsk
        self.onDismiss = onDismiss
        self.lifted = lifted()
    }

    var body: some View {
        ZStack {
            Palette.scrim
                .ignoresSafeArea()
                .opacity(isLifted ? 1 : 0)
                .onTapGesture {
                    ThreadLog.note("message menu scrim tapped")
                    onDismiss()
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Close")
            GeometryReader { geometry in
                let space = geometry.frame(in: .global)
                let row = rowFrame.offsetBy(dx: -space.minX, dy: -space.minY)
                let finger = pressPoint.map { $0.y - space.minY } ?? visibleMiddle(of: row, in: geometry.size)
                let actions = actionsTop(near: finger, in: geometry.size)
                let menuSize = fittedMenuHeight(in: geometry.size)
                ZStack(alignment: .topLeading) {
                    lifted
                        .frame(width: row.width, height: row.height, alignment: .top)
                        .shadow(color: Palette.shadow, radius: isLifted ? 18 : 0, y: 8)
                        .position(x: row.midX, y: row.midY)
                    aligned(bar, width: geometry.size.width)
                        .position(x: geometry.size.width / 2, y: actions + reactionBarHeight / 2)
                    aligned(menu(height: menuSize), width: geometry.size.width)
                        .position(x: geometry.size.width / 2, y: actions + reactionBarHeight + reactionGap + menuSize / 2)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .onAppear {
            onShown()
            if reduceMotion {
                isLifted = true
            } else {
                withAnimation(Motion.lift) {
                    isLifted = true
                }
            }
        }
        .task(id: message.id) {
            guard hasMedia else {
                return
            }
            files = await MessageFiles.files(of: message, from: model.media)
            hasFilesFailed = files == nil
        }
    }

    /// Where the bar's top goes, with the menu under it: just above the finger at `y`
    /// when both fit there, else just below it, and on screen either way.
    private func actionsTop(near y: CGFloat, in size: CGSize) -> CGFloat {
        let height = reactionBarHeight + reactionGap + fittedMenuHeight(in: size)
        let above = y - fingerClearance - height
        if above >= reactionGap {
            return above
        }
        return max(reactionGap, min(y + fingerClearance, size.height - height - reactionGap))
    }

    /// The middle of what shows of the row, for a message lifted with no finger on it.
    private func visibleMiddle(of row: CGRect, in size: CGSize) -> CGFloat {
        (max(row.minY, 0) + min(row.maxY, size.height)) / 2
    }

    private var menuHeight: CGFloat {
        CGFloat(menuCount) * menuRowHeight + 16 + timestampHeight
    }

    @ScaledMetric(relativeTo: .caption) private var timestampHeight: CGFloat = 58

    private func fittedMenuHeight(in size: CGSize) -> CGFloat {
        min(menuHeight, max(44, size.height - reactionBarHeight - 3 * reactionGap))
    }

    private var hasText: Bool {
        !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Attachments the gateway has kept, so they can be read back to share.
    private var hasMedia: Bool {
        message.rev != nil && !message.media.isEmpty
    }

    private var menuCount: Int {
        1 + (hasText ? 2 : 0) + (hasText || hasMedia ? 1 : 0) + (onAsk == nil ? 0 : 1)
    }

    /// The words as a person reads them.
    private var words: String {
        let isAssistant = model.room.participant(message.author)?.kind == .assistant
        return isAssistant ? MessagePlainText.text(of: message.text, calendar: .current) : message.text
    }

    private var isSpeaking: Bool { model.messageSpeech.messageID == message.id }
    private var spokenWords: String {
        let plain = try? AttributedString(markdown: words, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        return plain.map { String($0.characters) } ?? words
    }

    /// A peer assistant keeps her own voice; human messages use this phone's assistant.
    private var speaker: (voice: String?, name: String)? {
        if model.room.participant(message.author)?.kind == .assistant,
           message.author != model.room.me?.assistant {
            guard let peer = model.room.peerAssistant else { return nil }
            return (peer.voice, peer.name)
        }
        return (nil, model.assistantName)
    }

    private func speak() {
        if isSpeaking {
            model.messageSpeech.stop()
        } else if let speaker {
            model.messageSpeech.speak(messageID: message.id, text: spokenWords, voice: speaker.voice, name: speaker.name)
        }
        onDismiss()
    }

    /// The bar and the menu sit on the message's own side, like its bubble.
    private func aligned(_ content: some View, width: CGFloat) -> some View {
        HStack {
            if isOwn {
                Spacer(minLength: 0)
            }
            content
            if !isOwn {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .frame(width: width)
    }

    private var bar: some View {
        let mine = message.reactions.first { $0.author == model.room.me?.person }?.emoji
        return HStack(spacing: 2) {
            ForEach(Tapback.allCases, id: \.self) { tapback in
                Button {
                    onReact(tapback.emoji)
                } label: {
                    Text(tapback.emoji)
                        .font(.system(size: 28))
                        .frame(width: 42, height: 42)
                        .background(mine == tapback.emoji ? Palette.highlight.opacity(0.25) : .clear, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mine == tapback.emoji ? "Remove \(tapback.name.lowercased())" : tapback.name)
                .accessibilityAddTraits(mine == tapback.emoji ? .isSelected : [])
            }
            if let mine, Tapback(rawValue: mine) == nil {
                Button {
                    onReact(mine)
                } label: {
                    Text(mine)
                        .font(.system(size: 28))
                        .frame(width: 42, height: 42)
                        .background(Palette.highlight.opacity(0.25), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(mine)")
                .accessibilityAddTraits(.isSelected)
            }
            Button {
                isPickingEmoji = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Palette.secondaryText)
                    .frame(width: 42, height: 42)
                    .background(isPickingEmoji ? Palette.highlight.opacity(0.25) : .clear, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("React with any emoji")
            .accessibilityHint("Opens the emoji keyboard")
            .background {
                EmojiKeyboardField(isOpen: $isPickingEmoji, onPick: onReact)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: reactionBarHeight)
        .rainbowGlass(in: Capsule())
        .scaleEffect(isLifted || reduceMotion ? 1 : 0.5, anchor: isOwn ? .bottomTrailing : .bottomLeading)
        .opacity(isLifted ? 1 : 0)
    }

    private func menu(height: CGFloat) -> some View {
        ScrollView {
        VStack(spacing: 0) {
            menuRow("Reply", symbol: "arrowshape.turn.up.left", action: onReply)
            if hasText {
                menuRow("Copy", symbol: "doc.on.doc") {
                    UIPasteboard.general.string = words
                    onDismiss()
                }
                menuRow(isSpeaking ? "Stop Speaking" : "Speak", symbol: isSpeaking ? "stop.fill" : "speaker.wave.2", action: speak)
                    .disabled(!isSpeaking && (speaker == nil || spokenWords.isEmpty || model.call != nil || message.status == .streaming))
                    .accessibilityIdentifier("message.speak")
            }
            if hasMedia {
                shareFiles
            } else if hasText {
                ShareLink(item: words) {
                    menuLabel("Share", symbol: "square.and.arrow.up")
                }
                .buttonStyle(.plain)
            }
            if let onAsk {
                Button(action: onAsk) {
                    menuLabel("Ask \(model.assistantName)", symbol: "sparkles", glyph: Palette.goldText)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Replies quoting this message, asking \(model.assistantName)")
            }
            Divider()
                .padding(.horizontal, 16)
            Text("Sent \(message.sentAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(Palette.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: timestampHeight)
                .padding(.horizontal, 12)
                .accessibilityIdentifier("message.sent-time")
        }
        .padding(.vertical, 8)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 230, height: height)
        .rainbowGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .scaleEffect(isLifted || reduceMotion ? 1 : 0.5, anchor: isOwn ? .topTrailing : .topLeading)
        .opacity(isLifted ? 1 : 0)
    }

    /// The attachments, with the words beside them for an app that takes both. Until they
    /// are read the row waits, and it stays dim when one could not be read.
    @ViewBuilder
    private var shareFiles: some View {
        if let files {
            ShareLink(items: files, message: hasText ? Text(words) : nil) {
                menuLabel("Share", symbol: "square.and.arrow.up")
            }
            .buttonStyle(.plain)
        } else {
            HStack {
                Text("Share")
                Spacer()
                if hasFilesFailed {
                    Image(systemName: "exclamationmark.triangle")
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .font(.body)
            .foregroundStyle(Palette.secondaryText)
            .padding(.horizontal, 16)
            .frame(minHeight: menuRowHeight)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(hasFilesFailed ? "Share is not available, the attachment could not be read" : "Share, getting the attachments ready")
        }
    }

    private func menuRow(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            menuLabel(title, symbol: symbol)
        }
        .buttonStyle(.plain)
    }

    private func menuLabel(_ title: String, symbol: String, glyph: Color = Palette.secondaryText) -> some View {
        HStack {
            Text(title)
            Spacer()
            Image(systemName: symbol)
                .foregroundStyle(glyph)
        }
        .font(.body)
        .foregroundStyle(Palette.text)
        .padding(.horizontal, 16)
        .frame(minHeight: menuRowHeight)
        .contentShape(Rectangle())
    }
}

