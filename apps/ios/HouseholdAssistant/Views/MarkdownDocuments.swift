// Each stretch of Markdown in a finished answer, parsed once into the renderer's document
// and kept by its text, so its bubble draws it whole from its first frame.
//
// The renderer (SwiftStreamingMarkdown) parses only asynchronously: its `MarkdownView`
// drew an empty document first and filled it a moment later, so every assistant row was
// laid out empty and then grew, and the thread, anchored at its newest message, corrected
// its offset each time one did. Scrolling built rows all the time, and each one grew.
// Neither the parser nor the document has a synchronous way in, so the documents are
// parsed off the main thread ahead of the rows instead: both threads after every connect
// (AppModel), and everything in the open thread whenever its messages change (RoomView).
// A row then draws its document straight from here with `DocumentView`. Only a text no one
// has prepared yet, such as a whole message landing while its thread is open, draws empty
// for the moment its parse takes.

import SwiftStreamingMarkdown
import SwiftUI

@MainActor
enum MarkdownDocuments {
    struct Key: Hashable {
        let text: String
        let style: ReadingStyle
    }

    /// Enough for both threads and the older pages read into them.
    private static let kept = BoundedCache<Key, RenderableDocument>(capacity: 512)
    /// Opening the thread and warming its history can ask for the same text together.
    private static var parsing: [Key: Task<RenderableDocument, Never>] = [:]
    /// The newest answers of a thread made ready ahead: the screens a thread opens on and
    /// the next few above. Older ones parse as they come near the screen. All of a thread
    /// of thousands overflowed what is kept, so each change parsed them all again and the
    /// oldest pushed out the newest it had just made ready.
    static let preparedAtMost = 120

    /// The document kept for `text`, or nil when it has not been parsed.
    static func document(for text: String, style: ReadingStyle = .standard) -> RenderableDocument? {
        kept.value(for: Key(text: text, style: style))
    }

    /// The document for `text`, parsed off the main thread the first time and kept.
    static func parse(_ text: String, style: ReadingStyle = .standard) async -> RenderableDocument {
        let key = Key(text: text, style: style)
        if let document = kept.value(for: key) {
            return document
        }
        if let task = parsing[key] {
            let document = await task.value
            kept.insert(document, for: key)
            return document
        }
        let task = Task { await MarkdownParserImpl().parse(text: text, config: style.config) }
        parsing[key] = task
        let document = await task.value
        kept.insert(document, for: key)
        parsing[key] = nil
        return document
    }

    /// Only the messages actually on screen gate the first reveal, never older history.
    static func areReady(_ messages: [RoomMessage], participants: [RoomParticipant], me: RoomSelf?, style: ReadingStyle) -> Bool {
        let assistants = Set(participants.filter { $0.kind == .assistant }.map(\.id))
        return messages.allSatisfy { message in
            guard assistants.contains(message.author), message.approval == nil, message.status != .streaming else { return true }
            return RoomMarkdown.documentTexts(in: message.text, participants: participants, me: me).allSatisfy {
                document(for: $0, style: style) != nil
            }
        }
    }

    /// Parses every stretch the newest finished answers in `messages` draw, the newest first,
    /// since the newest are what a thread opens on, up to `preparedAtMost` answers.
    static func prepare(_ messages: [RoomMessage], participants: [RoomParticipant], me: RoomSelf?, style: ReadingStyle = .standard) async {
        let assistants = Set(participants.filter { $0.kind == .assistant }.map(\.id))
        let answers = messages.reversed().lazy.filter { message in
            assistants.contains(message.author) && message.approval == nil && message.status != .streaming
        }
        for message in answers.prefix(preparedAtMost) {
            for text in RoomMarkdown.documentTexts(in: message.text, participants: participants, me: me) {
                if Task.isCancelled {
                    return
                }
                _ = await parse(text, style: style)
            }
        }
    }
}

