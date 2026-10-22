// A conversation saved as plain text to share, and an assistant's message as plain words:
// who said what and when, attachments named and never copied, cards read out as lines.

import Foundation
import XCTest
@testable import HouseholdAssistant

final class TranscriptTests: XCTestCase {
    func testCopyKeepsTheEntireLongMarkdownAndReadableCardsWithoutInternalPayloads() {
        let opening = "# Long answer\n\n" + String(repeating: "A **complete** paragraph with 🏡 and a link [home](https://example.invalid).\n\n", count: 160)
        let final = "Unique final paragraph, copy contract 41b9."
        let card = "```steward-card\n{\"type\":\"copy\",\"text\":\"4821\",\"label\":\"Gate code\"}\n```"
        let internalCard = "```steward-card\n{\"type\":\"followups\",\"items\":[{\"text\":\"Hidden followup\",\"icon\":\"reminder\"}]}\n```"
        let message = opening + card + "\n\n" + internalCard + "\n\n" + final
        XCTAssertGreaterThan(message.utf16.count, 8_000)

        let copied = MessagePlainText.text(of: message, calendar: .current)

        XCTAssertEqual(copied, opening + "Gate code: 4821\n\n" + final)
        XCTAssertFalse(copied.contains("steward-card"))
        XCTAssertFalse(copied.contains("Hidden followup"))
    }

    private static let participants = [
        RoomParticipant(id: "franco", name: "Leo", kind: .person, isOwner: true),
        RoomParticipant(id: "gia", name: "Rosa", kind: .person, isOwner: false),
        RoomParticipant(id: "corey", name: "Corey", kind: .assistant, isOwner: false, emoji: "\u{1F989}"),
    ]

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: -4 * 3600)!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    /// 15 October 2026 at 18:12 in the calendar's zone.
    private static let evening = Date(timeIntervalSince1970: 1_792_102_320)

    private func kept(
        _ id: String,
        _ author: String,
        _ text: String,
        minutesAfter minutes: Double,
        media: [RoomMedia] = [],
        replyTo: String? = nil,
        rev: Int
    ) -> RoomMessage {
        RoomMessage(
            id: id,
            author: author,
            text: text,
            media: media,
            replyTo: replyTo,
            sentAt: Self.evening.addingTimeInterval(minutes * 60),
            status: .sent,
            rev: rev
        )
    }

    // MARK: - The transcript

    func testATranscriptSaysWhoSaidWhatDayByDay() {
        // Arrange
        let messages = [
            kept("m-1", "gia", "Dinner is ready \u{1F35D}", minutesAfter: 0, rev: 1),
            kept("m-2", "franco", "Leaving work now.\nSave me some!", minutesAfter: 3, replyTo: "m-1", rev: 2),
            kept("a-3", "corey", "Morning! The bus leaves at 9:00.", minutesAfter: 14 * 60, rev: 3),
        ]
        let nextMorning = Self.evening.addingTimeInterval(14 * 60 * 60)

        // Act
        let transcript = ConversationTranscript(
            title: "The Fam",
            messages: messages,
            participants: Self.participants,
            savedAt: nextMorning,
            calendar: calendar
        )

        // Assert
        let day = { ConversationTranscript.day($0, calendar: self.calendar) }
        let clock = { ConversationTranscript.clock($0, calendar: self.calendar) }
        XCTAssertEqual(transcript.text, """
        The Fam
        Saved from Steward AI on \(day(nextMorning))

        \(day(Self.evening))

        \(clock(messages[0].sentAt)), Rosa:
        Dinner is ready \u{1F35D}

        \(clock(messages[1].sentAt)), Leo, replying to Rosa:
        Leaving work now.
        Save me some!

        \(day(nextMorning))

        \(clock(messages[2].sentAt)), Corey:
        Morning! The bus leaves at 9:00.

        """)
        XCTAssertTrue(day(Self.evening).contains("October 15, 2026"), day(Self.evening))
        XCTAssertTrue(day(nextMorning).contains("October 16, 2026"), day(nextMorning))
    }

    /// A message still on its way, one that failed and a reply still streaming are not
    /// what was said yet.
    func testACallIsItsLengthThenWhatEachSaidOnIt() throws {
        // Arrange
        let started = Int(Self.evening.timeIntervalSince1970 * 1000)
        let entry = try JSONValue.object([
            "id": .string("call:c-1"), "rev": .number(5), "kind": .string("call"), "conversation": .string("direct"),
            "author": .string("franco"), "at": .number(Double(started)), "endedAt": .number(Double(started + 247_000)),
            "with": .string("corey"), "turnIds": .array([]), "isCut": .bool(true),
            "transcript": .array([
                .object(["author": .string("franco"), "text": .string("What's on today?"), "at": .number(Double(started))]),
                .object(["author": .string("corey"), "text": .string("Dentist at 3:30."), "at": .number(Double(started + 3_000))]),
            ]),
        ]).decoded(as: RoomEntry.self)
        let call = RoomMessage(entry)

        // Act
        let transcript = ConversationTranscript(title: "Corey", messages: [call], participants: Self.participants, savedAt: Self.evening, calendar: calendar)

        // Assert
        let clock = ConversationTranscript.clock(call.sentAt, calendar: calendar)
        XCTAssertTrue(transcript.text.hasSuffix("""
        \(clock), Leo, a call with Corey, 4:07:
        Leo: What's on today?
        Corey: Dentist at 3:30.
        (Only the start of this call was kept.)

        """), transcript.text)
    }

    func testOnlyWhatTheGatewayKeptIsInTheTranscript() {
        var sending = kept("m-2", "franco", "On my way", minutesAfter: 1, rev: 0)
        sending.rev = nil
        sending.status = .sending
        var failed = kept("m-3", "franco", "Book the car wash", minutesAfter: 2, rev: 0)
        failed.rev = nil
        failed.status = .failed("refused")
        var streaming = kept("run:1", "corey", "Tonight is pas", minutesAfter: 3, rev: 0)
        streaming.rev = nil
        streaming.status = .streaming

        let transcript = ConversationTranscript(
            title: "Corey",
            messages: [kept("d-1", "franco", "What is on tonight?", minutesAfter: 0, rev: 1), sending, failed, streaming],
            participants: Self.participants,
            savedAt: Self.evening,
            calendar: calendar
        )

        XCTAssertTrue(transcript.text.contains("What is on tonight?"))
        for unsaid in ["On my way", "Book the car wash", "Tonight is pas"] {
            XCTAssertFalse(transcript.text.contains(unsaid), unsaid)
        }
    }

    func testAttachmentsAreNamedAndNeverCopied() {
        let photo = RoomMedia(id: String(repeating: "a", count: 64), kind: .photo, mime: "image/jpeg", bytes: 180_000, width: 1200, height: 900)
        let voice = RoomMedia(id: String(repeating: "b", count: 64), kind: .voice, mime: "audio/mp4", bytes: 9_000, durationMs: 6_000)
        let slip = RoomMedia(id: String(repeating: "c", count: 64), kind: .file, mime: "application/pdf", bytes: 40_000, name: "Field trip permission slip.pdf")
        let clip = RoomMedia(id: String(repeating: "d", count: 64), kind: .video, mime: "video/mp4", bytes: 900_000, durationMs: 72_000)

        let transcript = ConversationTranscript(
            title: "The Fam",
            messages: [
                kept("m-1", "gia", "", minutesAfter: 0, media: [photo, voice], rev: 1),
                kept("a-2", "corey", "Here is the slip.", minutesAfter: 1, media: [slip, clip], rev: 2),
            ],
            participants: Self.participants,
            savedAt: Self.evening,
            calendar: calendar
        )

        XCTAssertTrue(transcript.text.contains(", Rosa:\n[Photo]\n[Voice note, 0:06]\n"), transcript.text)
        XCTAssertTrue(transcript.text.contains(", Corey:\nHere is the slip.\n[File: Field trip permission slip.pdf]\n[Video, 1:12]\n"), transcript.text)
        for id in [photo.id, voice.id, slip.id, clip.id] {
            XCTAssertFalse(transcript.text.contains(id), "no attachment's hash, let alone its bytes")
        }
    }

    func testSomeoneTheRoomNoLongerKnowsIsStillShown() {
        let transcript = ConversationTranscript(
            title: "The Fam",
            messages: [kept("m-1", "grandma", "Hello all", minutesAfter: 0, rev: 1)],
            participants: Self.participants,
            savedAt: Self.evening,
            calendar: calendar
        )

        XCTAssertTrue(transcript.text.contains(", Someone:\nHello all\n"), transcript.text)
    }

    func testTheFileIsNamedByTheConversationAndTheDayItWasSaved() {
        let cases: [(title: String, fileName: String)] = [
            ("The Fam", "The Fam 2026-10-15.txt"),
            ("Corey", "Corey 2026-10-15.txt"),
            ("A/B: C", "A-B- C 2026-10-15.txt"),
        ]
        for (title, fileName) in cases {
            let transcript = ConversationTranscript(title: title, messages: [], participants: [], savedAt: Self.evening, calendar: calendar)
            XCTAssertEqual(transcript.fileName, fileName, title)
        }
    }

    func testATranscriptIsWrittenAsAFileUnderItsName() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
        }
        let transcript = ConversationTranscript(
            title: "The Fam",
            messages: [kept("m-1", "gia", "Dinner is ready", minutesAfter: 0, rev: 1)],
            participants: Self.participants,
            savedAt: Self.evening,
            calendar: calendar
        )

        let file = try transcript.write(into: folder)
        let again = try transcript.write(into: folder)

        XCTAssertEqual(file.lastPathComponent, "The Fam 2026-10-15.txt")
        XCTAssertEqual(again, file, "saving again replaces it")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), transcript.text)
    }

    // MARK: - An assistant's words

    func testAnAssistantsCardsReadAsPlainWords() {
        let cases: [(name: String, message: String, plain: String)] = [
            ("words alone", "**Tomorrow**\n- 9:00 Standup", "**Tomorrow**\n- 9:00 Standup"),
            (
                "a table",
                "Here you go.\n\n```steward-card\n{\"type\":\"table\",\"title\":\"Groceries\",\"columns\":[\"Week\",\"Spent\"],\"rows\":[[\"1\",\"$142\"],[\"2\",\"$98\"]]}\n```",
                "Here you go.\n\nGroceries\nWeek | Spent\n1 | $142\n2 | $98"
            ),
            (
                "a checklist",
                "```steward-card\n{\"type\":\"checklist\",\"id\":\"beach\",\"title\":\"Beach bag\",\"items\":[{\"text\":\"Sunscreen\",\"done\":true},{\"text\":\"Towels\",\"done\":false}]}\n```",
                "Beach bag\n[x] Sunscreen\n[ ] Towels"
            ),
            (
                "something to copy",
                "The code:\n```steward-card\n{\"type\":\"copy\",\"label\":\"Gate code\",\"text\":\"4821\"}\n```",
                "The code:\n\nGate code: 4821"
            ),
            (
                "a chart",
                "```steward-card\n{\"type\":\"chart\",\"kind\":\"bar\",\"title\":\"Spend\",\"x\":[\"Sep\",\"Oct\"],\"series\":[{\"name\":\"Groceries\",\"values\":[640,512.5]}],\"unit\":\"$\"}\n```",
                "Spend\nSep: Groceries $640\nOct: Groceries $512.50"
            ),
            (
                "where the answer came from",
                "It opens at 7.\n```steward-card\n{\"type\":\"sources\",\"links\":[{\"url\":\"https://www.cityparks.example/pool\",\"title\":\"City pool hours\"},{\"url\":\"https://www.news.example/a\"}]}\n```",
                "It opens at 7.\n\nSources:\nCity pool hours https://www.cityparks.example/pool\nnews.example https://www.news.example/a"
            ),
            (
                "a budget",
                "```steward-card\n{\"type\":\"pocketpiggies\",\"card\":\"budget\",\"month\":\"October\",\"spent\":1284.5,\"limit\":2000,\"daysLeft\":16}\n```",
                "October budget: $1,284.50 of $2,000, 16 days left"
            ),
            (
                "a card that cannot be read",
                "```steward-card\n{\"type\":\"table\"}\n```",
                "{\"type\":\"table\"}"
            ),
        ]
        for (name, message, plain) in cases {
            XCTAssertEqual(MessagePlainText.text(of: message, calendar: calendar), plain, name)
        }
    }

    func testAnEventSaysWhenAndWhere() {
        let message = "```steward-card\n{\"type\":\"event\",\"title\":\"Dentist\",\"start\":\"2026-10-16T15:30:00-04:00\",\"location\":\"Main St Dental\"}\n```"

        let plain = MessagePlainText.text(of: message, calendar: calendar)

        let start = Date(timeIntervalSince1970: 1_792_179_000)
        XCTAssertEqual(plain, "Dentist\n\(ConversationTranscript.day(start, calendar: calendar)), \(ConversationTranscript.clock(start, calendar: calendar))\nMain St Dental")
    }

    func testAnAssistantsMessageIsSavedAsItsPlainWords() {
        let card = "Done.\n```steward-card\n{\"type\":\"copy\",\"text\":\"4821\"}\n```"

        let transcript = ConversationTranscript(
            title: "Corey",
            messages: [kept("a-1", "corey", card, minutesAfter: 0, rev: 1), kept("d-2", "franco", "```steward-card", minutesAfter: 1, rev: 2)],
            participants: Self.participants,
            savedAt: Self.evening,
            calendar: calendar
        )

        XCTAssertTrue(transcript.text.contains(", Corey:\nDone.\n\n4821\n"), transcript.text)
        XCTAssertTrue(transcript.text.contains(", Leo:\n```steward-card\n"), "a person's words are theirs as written")
    }
}
