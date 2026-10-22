// A conversation as plain text, to share as a file named by the conversation and the
// day it was saved: who said what and when, day by day, each attachment named in
// brackets, and an assistant's cards as plain lines (MessagePlainText).
//
// Only what the gateway kept is in it. It holds no byte of any photo or file, no hash a
// gateway keeps one under, and no signature, which the phone keeps on no message anyway.

import Foundation

struct ConversationTranscript: Equatable, Sendable {
    let text: String
    let fileName: String

    init(title: String, messages: [RoomMessage], participants: [RoomParticipant], savedAt: Date, calendar: Calendar) {
        let kept = messages.filter { $0.rev != nil }
        let byId = Dictionary(kept.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let people = Dictionary(participants.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func name(of author: String) -> String {
            people[author]?.name ?? "Someone"
        }

        var paragraphs = ["\(title)\nSaved from Steward AI on \(Self.day(savedAt, calendar: calendar))"]
        var shownDay: Date?
        for message in kept {
            let day = calendar.startOfDay(for: message.sentAt)
            if day != shownDay {
                paragraphs.append(Self.day(message.sentAt, calendar: calendar))
                shownDay = day
            }
            var heading = "\(Self.clock(message.sentAt, calendar: calendar)), \(name(of: message.author))"
            if let answered = message.replyTo.flatMap({ byId[$0] }) {
                heading += ", replying to \(name(of: answered.author))"
            }
            if let call = message.call {
                // A call is its length, then what each said on it.
                let lines = call.transcript.map { "\(name(of: $0.author)): \($0.text)" }
                let cut = call.isCut ? ["(Only the start of this call was kept.)"] : []
                paragraphs.append(([heading + ", a call with \(name(of: call.assistant)), \(call.length):"] + lines + cut).joined(separator: "\n"))
                continue
            }
            let isAssistant = people[message.author]?.kind == .assistant
            let words = isAssistant ? MessagePlainText.text(of: message.text, calendar: calendar) : message.text
            let said = [words.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }
                + message.media.map(Self.label)
            paragraphs.append(([heading + ":"] + said).joined(separator: "\n"))
        }
        text = paragraphs.joined(separator: "\n\n") + "\n"
        fileName = Self.fileName(title: title, day: savedAt, calendar: calendar)
    }

    /// Saves it under its name in `folder`, over any earlier save of the same day.
    func write(into folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(fileName)
        try Data(text.utf8).write(to: file, options: .atomic)
        return file
    }

    /// "Thursday, October 15, 2026", in the phone's own words for a day.
    static func day(_ date: Date, calendar: Calendar) -> String {
        date.formatted(Date.FormatStyle(date: .complete, time: .omitted, locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone))
    }

    /// "6:12 PM", or "18:12" where the phone keeps a 24-hour clock.
    static func clock(_ date: Date, calendar: Calendar) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone))
    }

    private static func label(_ media: RoomMedia) -> String {
        let length = media.durationMs.map { ", " + VoiceNoteGesture.clock(milliseconds: $0) } ?? ""
        switch media.kind {
        case .photo:
            return "[Photo]"
        case .video:
            return "[Video\(length)]"
        case .voice:
            return "[Voice note\(length)]"
        case .file:
            return "[File: \(media.name ?? "untitled")]"
        }
    }

    /// "The Fam 2026-10-15.txt": the day in digits, so a folder of them sorts by date.
    private static func fileName(title: String, day: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        let date = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        return PlainFileName.unique("\(title) \(date).txt", taken: [])
    }
}
