// A widget for one conversation, the assistant's thread or the family room, as the person
// chose with Edit Widget. On the Home Screen: its face with the unread count, the line it
// leads with or its newest lines, the glass microphone, which opens the conversation
// straight into a voice note, and Write where there is room. Tapping anywhere else opens
// the conversation. The Lock Screen's sizes are ConversationAccessoryView.
//
// A value in, a picture out, so the screenshot test draws every size from a snapshot made
// from the demo household. A new line slides in from below and the count ticks over; with
// Reduce Motion both only fade.

import AppIntents
import SwiftUI
import UIKit
import WidgetKit

struct ConversationWidgetView: View {
    let family: WidgetFamily
    let conversation: RoomConversation
    let snapshot: WidgetSnapshot
    var photos: [String: UIImage] = [:]
    /// The Lock Screen's rendering, for a screenshot test; nil takes the one iOS gives.
    var accessoryRenderingMode: WidgetRenderingMode?

    @Environment(\.reducesMotion) private var reduceMotion
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.colorScheme) private var colorScheme

    private var content: WidgetConversation {
        WidgetConversation(conversation: conversation, snapshot: snapshot, photos: photos)
    }

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular, .accessoryRectangular, .accessoryInline:
                ConversationAccessoryView(family: family, content: content, renderingMode: accessoryRenderingMode)
            case .systemMedium:
                medium
            case .systemLarge, .systemExtraLarge:
                large
            default:
                small
            }
        }
        .animation(Motion.arrive(reduced: reduceMotion), value: content.thread)
        .containerBackground(for: .widget) {
            WidgetBackground()
        }
        .widgetURL(AppLink.conversation(conversation).url)
    }

    // MARK: - Sizes

    /// The face with its count, the microphone, the name and the line it leads with.
    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 4) {
                face(size: 52)
                    .overlay(alignment: .topTrailing) {
                        badge
                            .offset(x: 10, y: -6)
                    }
                Spacer(minLength: 0)
                recordButton(size: 40)
            }
            Spacer(minLength: 6)
            Text(content.title)
                .font(.headline)
                .foregroundStyle(Palette.text)
                .lineLimit(1)
                .widgetAccentable()
            Group {
                if let line = content.featured {
                    content.text(of: line, isNamed: conversation == .family)
                        .foregroundStyle(Palette.text)
                        .id(line.id)
                        .transition(Motion.bubbleTransition(isOwn: false, reduced: reduceMotion))
                } else {
                    Text(content.emptyText)
                        .foregroundStyle(Palette.secondaryText)
                }
            }
            .font(.footnote)
            .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The name and count over the newest three lines, with the microphone and Write down
    /// the side.
    private var medium: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                header(faceSize: 30)
                lines(count: 3, faceSize: 22) { line in
                    content.text(of: line, isNamed: true)
                        .font(.subheadline)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            VStack(spacing: 10) {
                recordButton(size: 44)
                writeButton(size: 44)
            }
            .frame(maxHeight: .infinity)
        }
    }

    /// The name, count and time over the newest five lines, each under its author, with
    /// Record and Write across the bottom.
    private var large: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                header(faceSize: 32)
                if let newest = content.thread.lines.last {
                    Text(newest.sentAt, style: .time)
                        .font(.footnote)
                        .foregroundStyle(Palette.secondaryText)
                }
            }
            lines(count: 5, faceSize: 34) { line in
                VStack(alignment: .leading, spacing: 1) {
                    Text(content.name(of: line.author))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.secondaryText)
                    content.text(of: line, isNamed: false)
                        .font(.subheadline)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Button(intent: OpenRecordingIntent(conversation: conversation)) {
                    capsule("Record", symbol: "mic.fill", tint: Palette.goldText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Record a voice note to \(content.title)")
                Link(destination: AppLink.write(conversation).url) {
                    capsule("Write", symbol: "square.and.pencil", tint: Palette.highlight)
                }
                .accessibilityLabel("Write to \(content.title)")
            }
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private func face(size: CGFloat) -> some View {
        switch conversation {
        case .family:
            WidgetFamilyFace(faces: snapshot.faces, photos: photos, size: size)
        case .direct:
            WidgetFace(look: content.assistantLook, photo: content.photo(of: snapshot.assistant), size: size, ring: snapshot.face(snapshot.assistant)?.ring)
        }
    }

    private func header(faceSize: CGFloat) -> some View {
        HStack(spacing: 8) {
            face(size: faceSize)
            Text(content.title)
                .font(.headline)
                .foregroundStyle(Palette.text)
                .lineLimit(1)
                .widgetAccentable()
            Spacer(minLength: 4)
            badge
        }
    }

    /// The newest lines, oldest first, each beside its author's face. A line that is new
    /// since the last time slides in from below.
    private func lines<Words: View>(
        count: Int,
        faceSize: CGFloat,
        @ViewBuilder words: @escaping (WidgetSnapshot.Line) -> Words
    ) -> some View {
        VStack(alignment: .leading, spacing: faceSize > 30 ? 8 : 6) {
            if content.thread.lines.isEmpty {
                Text(content.emptyText)
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryText)
            }
            ForEach(Array(content.thread.lines.suffix(count))) { line in
                HStack(alignment: faceSize > 30 ? .top : .center, spacing: 8) {
                    WidgetFace(look: content.look(of: line.author), photo: content.photo(of: line.author), size: faceSize, ring: snapshot.face(line.author)?.ring)
                    words(line)
                        .foregroundStyle(Palette.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .transition(Motion.bubbleTransition(isOwn: line.author == snapshot.me, reduced: reduceMotion))
            }
        }
    }

    /// How many are unread, in royal, ticking over as it changes. In a tinted widget the
    /// count is drawn in the accent on a ring, since a filled badge would hide it.
    @ViewBuilder
    private var badge: some View {
        if content.thread.unread > 0 {
            let isFilled = renderingMode == .fullColor
            Text(content.unreadText)
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(isFilled ? Color.white : Palette.highlight)
                .contentTransition(reduceMotion ? ContentTransition.opacity : .numericText(value: Double(content.thread.unread)))
                .padding(.horizontal, 7)
                .frame(minWidth: 24, minHeight: 24)
                .background {
                    if isFilled {
                        Capsule().fill(Palette.royal)
                    } else {
                        Capsule().strokeBorder(lineWidth: 1.5)
                    }
                }
                .widgetAccentable()
                .transition(Motion.popTransition(reduced: reduceMotion))
                .accessibilityLabel("\(content.thread.unread) unread")
        }
    }

    /// The conversation, straight into a voice note: it opens recording, locked, with the
    /// send arrow and the stop to listen back ready.
    private func recordButton(size: CGFloat) -> some View {
        Button(intent: OpenRecordingIntent(conversation: conversation)) {
            glassCircle(symbol: "mic.fill", tint: Palette.goldText, size: size)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Record a voice note to \(content.title)")
    }

    /// The conversation, with the keyboard up to write in it.
    private func writeButton(size: CGFloat) -> some View {
        Link(destination: AppLink.write(conversation).url) {
            glassCircle(symbol: "square.and.pencil", tint: Palette.highlight, size: size)
        }
        .accessibilityLabel("Write to \(content.title)")
    }

    /// The app's glass drawn the way a widget can draw it: a frosted disc with the scheme's rim.
    private func glassCircle(symbol: String, tint: Color, size: CGFloat) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(tint)
            .widgetAccentable()
            .frame(width: size, height: size)
            .background(Circle().fill(Palette.surface))
            .overlay {
                Circle()
                    .strokeBorder(glassRim, lineWidth: 1)
                    .opacity(0.7)
            }
    }

    private func capsule(_ title: String, symbol: String, tint: Color) -> some View {
        Label {
            Text(title)
                .foregroundStyle(Palette.text)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .widgetAccentable()
        }
        .font(.subheadline.weight(.semibold))
        .frame(maxWidth: .infinity, minHeight: 42)
        .background(Capsule().fill(Palette.surface))
        .overlay {
            Capsule()
                .strokeBorder(glassRim, lineWidth: 1)
                .opacity(0.7)
        }
    }

    /// The rainbow sheen in the light and gold glass in the dark, as the app's glass has it.
    private var glassRim: AngularGradient {
        colorScheme == .dark ? Palette.rim(rainbow: RimStyle.standard.dark) : Palette.sheen
    }
}
