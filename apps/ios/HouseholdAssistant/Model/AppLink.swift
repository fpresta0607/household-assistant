// Where a `steward://` link opens the app: one of its conversations, one of them with the
// keyboard up to write in it or with a voice note already recording, or Talk. The
// widgets and the Talk control open the app through these. A pairing link,
// `steward://pair?code=`, is a setup code, which PairingCode reads before any of these.
// PocketPiggies' consent page sends the person back with `steward://pocketpiggies/linked`
// once the household's account is linked (docs/deploy/pocketpiggies-server.md), which opens
// their own conversation, where their assistant answers from it.

import Foundation

enum AppLink: Equatable, Sendable {
    /// `steward://family` or `steward://direct`: the conversation, at its newest message.
    case conversation(RoomConversation)
    /// `steward://family/write`: the conversation, with the keyboard up.
    case write(RoomConversation)
    /// `steward://family/record`: the conversation, recording a voice note.
    case record(RoomConversation)
    /// `steward://talk`: hands-free Talk with this phone's assistant.
    case talk

    static let scheme = "steward"
    private static let talkHost = "talk"
    private static let writePath = "/write"
    private static let recordPath = "/record"
    private static let pocketPiggiesHost = "pocketpiggies"
    private static let linkedPath = "/linked"

    /// Anything else, an unknown place or another app's link, is no place in the app.
    init?(url: URL) {
        guard
            let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
            parts.scheme?.lowercased() == Self.scheme,
            let host = parts.host?.lowercased()
        else {
            return nil
        }
        let path = parts.path.lowercased()
        let isPlain = path.isEmpty || path == "/"
        if host == Self.talkHost, isPlain {
            self = .talk
        } else if let conversation = RoomConversation(rawValue: host), isPlain {
            self = .conversation(conversation)
        } else if let conversation = RoomConversation(rawValue: host), Self.isPath(path, Self.writePath) {
            self = .write(conversation)
        } else if let conversation = RoomConversation(rawValue: host), Self.isPath(path, Self.recordPath) {
            self = .record(conversation)
        } else if host == Self.pocketPiggiesHost, Self.isPath(path, Self.linkedPath) {
            self = .conversation(.direct)
        } else {
            return nil
        }
    }

    var url: URL {
        switch self {
        case .conversation(let conversation):
            return URL(string: "\(Self.scheme)://\(conversation.rawValue)")!
        case .write(let conversation):
            return URL(string: "\(Self.scheme)://\(conversation.rawValue)\(Self.writePath)")!
        case .record(let conversation):
            return URL(string: "\(Self.scheme)://\(conversation.rawValue)\(Self.recordPath)")!
        case .talk:
            return URL(string: "\(Self.scheme)://\(Self.talkHost)")!
        }
    }

    /// `path` is `expected`, with or without a trailing slash.
    private static func isPath(_ path: String, _ expected: String) -> Bool {
        path == expected || path == expected + "/"
    }
}
