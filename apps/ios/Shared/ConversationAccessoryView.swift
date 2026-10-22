// A conversation's widget on the Lock Screen, where iOS draws it in one tint over the
// wallpaper: the face with the unread count in the circle, who said the newest line and
// the line itself in the rectangle, and one line by the date. Tapping opens the
// conversation, which ConversationWidgetView links for every size.
//
// The count ticks over and a new line slides in from below; with Reduce Motion both only
// fade.
//
// iOS draws the Lock Screen vibrant, from each pixel's brightness, or in the accent: a
// photo or an emoji there comes out a dim, soft blot. So in those modes the circle shows a
// glyph made of strokes, the assistant's initial or the family's three, which stays sharp
// and bright, and only a full-colour rendering shows the photo.

import SwiftUI
import UIKit
import WidgetKit

struct ConversationAccessoryView: View {
    let family: WidgetFamily
    let content: WidgetConversation
    /// How iOS renders it, when a screenshot test draws it as the Lock Screen would; nil
    /// takes the mode iOS gives the widget.
    var renderingMode: WidgetRenderingMode?

    @Environment(\.reducesMotion) private var reduceMotion
    @Environment(\.widgetRenderingMode) private var givenRenderingMode

    private var isFullColor: Bool {
        (renderingMode ?? givenRenderingMode) == .fullColor
    }

    var body: some View {
        switch family {
        case .accessoryCircular:
            circular
        case .accessoryInline:
            inline
        default:
            rectangular
        }
    }

    private var unread: Int {
        content.thread.unread
    }

    /// The assistant's face, or the family's three, with the count under it.
    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                mark(size: unread > 0 ? 30 : 40)
                if unread > 0 {
                    Text(content.unreadText)
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(reduceMotion ? ContentTransition.opacity : .numericText(value: Double(unread)))
                        .widgetAccentable()
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(unread > 0 ? "\(content.title), \(unread) unread" : content.title)
    }

    @ViewBuilder
    private func mark(size: CGFloat) -> some View {
        switch content.conversation {
        case .family:
            Image(systemName: "person.3.fill")
                .font(.system(size: size * 0.5, weight: .semibold))
                .widgetAccentable()
        case .direct:
            if !isFullColor {
                initial(size: size)
            } else if let photo = content.photo(of: content.snapshot.assistant) {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else if let emoji = content.snapshot.assistantEmoji {
                Text(emoji)
                    .font(.system(size: size * 0.7))
            } else {
                Image(systemName: "sparkle")
                    .font(.system(size: size * 0.5, weight: .semibold))
            }
        }
    }

    /// The assistant's initial in a ring, bold and rounded, for the vibrant and accented
    /// Lock Screen; the sparkle before the phone knows its assistant's name.
    @ViewBuilder
    private func initial(size: CGFloat) -> some View {
        if let name = content.snapshot.assistantName, let letter = name.first {
            Text(String(letter).uppercased())
                .font(.system(size: size * 0.56, weight: .heavy, design: .rounded))
                .frame(width: size, height: size)
                .overlay {
                    Circle()
                        .strokeBorder(lineWidth: max(2, size * 0.07))
                }
                .widgetAccentable()
        } else {
            Image(systemName: "sparkle")
                .font(.system(size: size * 0.5, weight: .bold))
                .widgetAccentable()
        }
    }

    /// "🌸 Denise · The Fam" and the count, over the line.
    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(heading)
                    .font(.headline)
                    .lineLimit(1)
                    .widgetAccentable()
                Spacer(minLength: 2)
                if unread > 0 {
                    Text(content.unreadText)
                        .font(.headline)
                        .monospacedDigit()
                        .contentTransition(reduceMotion ? ContentTransition.opacity : .numericText(value: Double(unread)))
                        .widgetAccentable()
                }
            }
            Group {
                if let line = content.featured {
                    content.text(of: line, isNamed: false)
                        .id(line.id)
                        .transition(Motion.bubbleTransition(isOwn: false, reduced: reduceMotion))
                } else {
                    Text(content.emptyText)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
            .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Motion.arrive(reduced: reduceMotion), value: content.featured?.id)
    }

    /// Who said the line the rectangle shows, with their emoji, and in the family room, where.
    private var heading: String {
        guard let author = content.featured?.author else {
            return content.title
        }
        let emoji = content.snapshot.face(author)?.emoji.map { $0 + " " } ?? ""
        let name = emoji + content.name(of: author)
        return content.conversation == .family ? name + " \u{00B7} " + content.title : name
    }

    /// One line by the date: how many are new, or the line itself, after this phone's
    /// assistant's emoji.
    private var inline: some View {
        let emoji = content.snapshot.assistantEmoji.map { $0 + " " } ?? ""
        return Group {
            if unread > 0 {
                Text(emoji + (content.conversation == .family ? "\(unread) new in \(content.title)" : "\(unread) new from \(content.title)"))
            } else if let line = content.featured {
                Text("\(emoji)\(content.text(of: line, isNamed: content.conversation == .family))")
            } else {
                Text(emoji + content.title)
            }
        }
    }
}
