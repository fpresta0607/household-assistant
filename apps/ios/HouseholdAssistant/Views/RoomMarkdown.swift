// An assistant's words, as the Markdown they are written in, with its cards drawn natively
// in between: tables, charts, checklists, events, emails and the rest. A list whose every
// item starts with a time is drawn as rows with the time in a chip (TimeRows).
//
// A reply still arriving is parsed again each time it grows and drawn by the renderer,
// whose new words fade in softly (and simply appear with Reduce Motion). A finished one is
// drawn from documents
// parsed once and kept (MarkdownDocuments), so it has its full height from its first
// frame. A card still arriving is a quiet placeholder until its block closes, then fades
// into place, and so do rows of times, line by line.
//
// Each @mention of someone in the room becomes a link to them, semibold and gold, which
// the room opens as that assistant's page. The renderer has one look for every link, so
// a person's name and any web link the assistant writes look the same way.

import SwiftStreamingMarkdown
import SwiftUI
import UIKit

struct RoomMarkdown: View {
    let message: RoomMessage
    let conversation: RoomConversation
    /// The carts here that a later message has replaced (CartReplacements).
    let replacedCarts: Set<String>

    @Environment(AppModel.self) private var model
    /// Decided once, when the bubble first appears, so a bubble never swaps renderers
    /// mid-life and jumps. A card that arrives in a live reply draws itself in.
    @State private var isLive: Bool

    init(message: RoomMessage, conversation: RoomConversation, replacedCarts: Set<String>) {
        self.message = message
        self.conversation = conversation
        self.replacedCarts = replacedCarts
        _isLive = State(initialValue: message.status == .streaming)
    }

    private var isStreaming: Bool {
        message.status == .streaming
    }

    /// The message as the gateway keeps it. A reply still streaming, or just finished and
    /// not yet kept, has no id the gateway knows, so its checklist cannot be ticked yet.
    private var keptId: String? {
        message.rev == nil ? nil : message.id
    }

    var body: some View {
        // A card refused here, such as an order in the family room, is not drawn at all.
        let segments = StewardCardParser.segments(in: message.text, isStreaming: isStreaming).filter { segment in
            if case .card(let card) = segment {
                return card.content.isShown(in: conversation)
            }
            return true
        }
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                switch segment {
                case .markdown(let markdown):
                    MarkdownStretch(
                        markdown: Self.linked(markdown, participants: model.room.participants, me: model.room.me),
                        isLive: isLive,
                        isGrowing: isStreaming && index == segments.count - 1
                    )
                case .card(let card):
                    CardView(
                        card: card,
                        messageId: keptId,
                        author: message.author,
                        conversation: conversation,
                        isArriving: isLive,
                        replacedCarts: replacedCarts
                    )
                    .transition(Motion.rowTransition)
                case .pendingCard:
                    PendingCard()
                        .transition(Motion.rowTransition)
                case .code(let code):
                    CodeBlockCard(text: code)
                }
            }
        }
    }

    /// The standard style remains available to previews and callers without a view.
    /// On screen, both renderers read the live environment's ReadingStyle instead.
    static var config: MarkdownRenderConfig { ReadingStyle.standard.config }

    /// A stretch of Markdown with each @mention of someone in the room as a link to them.
    static func linked(_ markdown: String, participants: [RoomParticipant], me: RoomSelf?) -> String {
        Mention.linked(markdown, spans: Mention.spans(in: markdown, participants: participants, me: me))
    }

    /// The Markdown a finished answer draws, stretch by stretch, exactly as its documents
    /// are kept: what is between its cards, with its mentions linked and its rows of times
    /// taken out.
    static func documentTexts(in text: String, participants: [RoomParticipant], me: RoomSelf?) -> [String] {
        StewardCardParser.segments(in: text, isStreaming: false).flatMap { segment -> [String] in
            guard case .markdown(let markdown) = segment else {
                return []
            }
            return TimeRows.blocks(in: linked(markdown, participants: participants, me: me), isStreaming: false).compactMap { block in
                if case .markdown(let stretch) = block {
                    return stretch
                }
                return nil
            }
        }
    }
}

/// One stretch of Markdown between cards, with any list of times in it drawn as rows.
private struct MarkdownStretch: View {
    let markdown: String
    let isLive: Bool
    /// Whether this stretch is the end of a reply still arriving.
    let isGrowing: Bool

    var body: some View {
        let blocks = TimeRows.blocks(in: markdown, isStreaming: isGrowing)
        ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
            switch block {
            case .markdown(let text):
                if isLive {
                    LiveMarkdown(text: text)
                } else {
                    SettledMarkdown(text: text)
                }
            case .rows(let rows):
                TimeRowList(rows: rows)
            }
        }
    }
}

/// One stretch of a finished answer, drawn from its kept document, which the thread has
/// usually parsed before the bubble is built. One that has not been is parsed here.
private struct SettledMarkdown: View {
    let text: String

    /// What a parse here gave, for a stretch nobody had prepared.
    @Environment(\.readingStyle) private var style
    @State private var parsed: RenderableDocument?
    @State private var parsedKey: MarkdownDocuments.Key?

    var body: some View {
        let key = MarkdownDocuments.Key(text: text, style: style)
        DocumentView(
            renderableDocument: MarkdownDocuments.document(for: text, style: style)
                ?? (parsedKey?.text == text ? parsed : nil) ?? .empty,
            config: style.config
        )
        .task(id: key) {
            let document = await MarkdownDocuments.parse(text, style: style)
            guard !Task.isCancelled else { return }
            parsed = document
            parsedKey = key
        }
    }
}

/// One stretch of Markdown in a reply still arriving, parsed again each time it grows. A
/// parse still running when more words come is dropped for the newer text.
///
/// It owns its parse rather than leaving it to the library's StreamedMarkdownView, which
/// reads its words in a task that its onDisappear cancels later, from another task. A
/// bubble whose cell left the screen and came straight back, as a thread's cells do while
/// it scrolls, had its new reader cancelled by the old one's end and drew nothing more:
/// the hitch test's streamed answer stayed an empty bubble 30 points tall.
private struct LiveMarkdown: View {
    let text: String

    @Environment(\.reducesMotion) private var reduceMotion
    @Environment(\.readingStyle) private var style
    @State private var document: RenderableDocument = .empty

    private var config: MarkdownRenderConfig {
        style.config.withShouldAnimateText(value: !reduceMotion)
    }

    var body: some View {
        DocumentView(renderableDocument: document, config: config)
            .task(id: MarkdownDocuments.Key(text: text, style: style)) {
                let parsed = await MarkdownParserImpl().parse(text: text, config: config)
                if !Task.isCancelled {
                    document = parsed
                }
            }
    }
}
