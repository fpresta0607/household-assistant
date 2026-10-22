// What Talk says an assistant is doing while its run uses a tool.

import XCTest
@testable import HouseholdAssistant

final class AssistantActivityTests: XCTestCase {
    func testAToolIsReadFromItsName() {
        let cases: [(String, AssistantActivity)] = [
            ("web_search", .webSearch),
            ("web_fetch", .webPage),
            ("browser", .webPage),
            ("recall", .memory),
            ("memory_search", .memory),
            ("memory_get", .memory),
            ("cron", .reminder),
            ("pocketpiggies_read", .budget),
            ("pocketpiggies_records", .budget),
            ("family_history", .familyChat),
            ("speak", .voiceNote),
            ("tts", .voiceNote),
            ("image", .photo),
            ("picture", .picture),
            ("image_generate", .picture),
            ("video", .video),
            ("video_generate", .video),
            ("read", .readingNotes),
            ("write", .writingNotes),
            ("edit", .writingNotes),
            ("apply_patch", .writingNotes),
            ("message", .message),
            ("sessions_spawn", .other),
            ("something_new", .other),
        ]
        for (name, activity) in cases {
            XCTAssertEqual(AssistantActivity(tool: name, command: nil), activity, name)
        }
    }

    func testACommandIsReadFromTheSkillItRuns() {
        let cases: [(String, AssistantActivity)] = [
            ("python3 ~/.openclaw/workspace/skills/apple-cal-anywhere/cal.py --apple-id a@b.c list", .calendar),
            ("gog calendar events --today", .calendar),
            ("gog gmail search 'from:school'", .mail),
            ("himalaya envelope list", .mail),
            ("python3 ~/.openclaw/workspace/skills/scripture/scripture.py ref \"John 3:16\"", .scripture),
            ("python3 ~/.openclaw/workspace/skills/coordinate/coordinate.py ask \"Is Rosa free?\"", .otherAssistant),
            ("ls -la", .other),
        ]
        for (command, activity) in cases {
            XCTAssertEqual(AssistantActivity(tool: "exec", command: command), activity, command)
        }
        XCTAssertEqual(AssistantActivity(tool: "exec", command: nil), .other)
        XCTAssertEqual(AssistantActivity(tool: "process", command: "gog calendar events"), .calendar)
    }

    func testEachActivityReadsAfterTheAssistantsName() {
        XCTAssertEqual(AssistantActivity.calendar.phrase(otherAssistant: nil), "checking the calendar")
        XCTAssertEqual(AssistantActivity.webSearch.phrase(otherAssistant: nil), "searching the web")
        XCTAssertEqual(AssistantActivity.reminder.phrase(otherAssistant: nil), "setting a reminder")
        XCTAssertEqual(AssistantActivity.otherAssistant.phrase(otherAssistant: "Denise"), "checking with Denise")
        XCTAssertEqual(AssistantActivity.otherAssistant.phrase(otherAssistant: nil), "checking with the other assistant")
        XCTAssertEqual(AssistantActivity.picture.phrase(otherAssistant: nil), "making a picture")
        XCTAssertEqual(AssistantActivity.video.phrase(otherAssistant: nil), "making a video")
        XCTAssertEqual(AssistantActivity.video.symbol, "film")
        XCTAssertEqual(AssistantActivity.other.phrase(otherAssistant: nil), "working on it")
    }

    func testEveryActivityHasWordsAndASymbol() {
        let all: [AssistantActivity] = [
            .calendar, .mail, .webSearch, .webPage, .scripture, .budget, .memory, .reminder, .familyChat,
            .otherAssistant, .voiceNote, .photo, .picture, .video, .readingNotes, .writingNotes, .message, .other,
        ]
        for activity in all {
            XCTAssertFalse(activity.phrase(otherAssistant: "Denise").isEmpty, "\(activity)")
            XCTAssertFalse(activity.symbol.isEmpty, "\(activity)")
        }
        XCTAssertEqual(Set(all.map { $0.phrase(otherAssistant: "Denise") }).count, all.count, "no two read the same")
    }
}
