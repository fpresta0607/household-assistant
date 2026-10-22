// What an assistant is busy with while its run uses a tool, in a few words and an SF
// Symbol: "checking the calendar", and once done, "checked the calendar".
//
// Read from the tool's name, and for a shell command from which of the box's skills it
// runs: the calendar, mail and the scripture database are skills the assistant runs as
// commands. The command itself is never kept or shown.

import Foundation

enum AssistantActivity: Equatable, Sendable {
    case calendar
    case mail
    case webSearch
    case webPage
    case scripture
    case budget
    case memory
    case reminder
    case familyChat
    case otherAssistant
    case voiceNote
    case photo
    case picture
    case video
    case readingNotes
    case writingNotes
    case message
    case other

    /// The box's skills a command may run, by what its command line names. The first
    /// that matches wins, so an Apple ID on a mail address still reads as the calendar.
    private static let skills: [(keywords: [String], activity: AssistantActivity)] = [
        (["calendar", "apple-cal", "caldav"], .calendar),
        (["gmail", "himalaya", "mail"], .mail),
        (["scripture"], .scripture),
        (["coordinate"], .otherAssistant),
    ]

    init(tool name: String, command: String?) {
        switch name {
        case "exec", "bash", "process":
            let line = command?.lowercased() ?? ""
            self = Self.skills.first { $0.keywords.contains(where: line.contains) }?.activity ?? .other
        case "web_search":
            self = .webSearch
        case "web_fetch", "browser":
            self = .webPage
        case "recall", "memory_search", "memory_get":
            self = .memory
        case "cron":
            self = .reminder
        case "family_history":
            self = .familyChat
        case "speak", "tts":
            self = .voiceNote
        case "image":
            self = .photo
        case "picture", "image_generate":
            self = .picture
        case "video", "video_generate":
            self = .video
        case "read":
            self = .readingNotes
        case "write", "edit", "apply_patch":
            self = .writingNotes
        case "message":
            self = .message
        default:
            self = name.hasPrefix("pocketpiggies") ? .budget : .other
        }
    }

    /// What follows "Corey is". The other assistant is named when it is known.
    func phrase(otherAssistant: String?) -> String {
        switch self {
        case .calendar: return "checking the calendar"
        case .mail: return "checking email"
        case .webSearch: return "searching the web"
        case .webPage: return "reading a web page"
        case .scripture: return "looking up scripture"
        case .budget: return "checking your budget"
        case .memory: return "searching its memory"
        case .reminder: return "setting a reminder"
        case .familyChat: return "reading the family chat"
        case .otherAssistant: return "checking with \(otherAssistant ?? "the other assistant")"
        case .voiceNote: return "recording a voice note"
        case .photo: return "looking at the photo"
        case .picture: return "making a picture"
        case .video: return "making a video"
        case .readingNotes: return "reading its notes"
        case .writingNotes: return "writing that down"
        case .message: return "sending a message"
        case .other: return "working on it"
        }
    }

    var symbol: String {
        switch self {
        case .calendar: return "calendar"
        case .mail: return "envelope"
        case .webSearch: return "globe"
        case .webPage: return "safari"
        case .scripture: return "book"
        case .budget: return "banknote"
        case .memory: return "brain"
        case .reminder: return "bell"
        case .familyChat: return "bubble.left.and.bubble.right"
        case .otherAssistant: return "person.2"
        case .voiceNote: return "waveform"
        case .photo: return "photo"
        case .picture: return "paintbrush"
        case .video: return "film"
        case .readingNotes: return "note.text"
        case .writingNotes: return "square.and.pencil"
        case .message: return "paperplane"
        case .other: return "gearshape"
        }
    }
}
