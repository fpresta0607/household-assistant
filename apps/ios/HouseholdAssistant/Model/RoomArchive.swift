// What this phone keeps of each conversation, so a thread opens from the phone at once,
// offline too, rather than waiting for its gateway (CFO notes section 21): the newest page
// the gateway sent, and every change to that conversation since, each as the gateway's
// own JSON. Read back, they go through the same models and the same thread code as when
// they arrived, so a kept thread is exactly the thread that was on screen.
//
// One file per conversation, written whole and protected by the phone's passcode. A file
// that cannot be read is simply not there: the gateway's next page replaces it. Beside them,
// what the person said with no link, kept until it goes out, so a message waiting when iOS
// closes the app still goes once it opens again, and the assistant's Today card for the
// top of Chats. Forgetting the assistant forgets them all.

import Foundation

struct RoomArchive: Sendable {
    /// One conversation as kept: its newest page, and its changes since, oldest first.
    struct Kept: Codable, Equatable, Sendable {
        var page: JSONValue
        var changes: [JSONValue] = []
    }

    /// A message said with no link, as it was said, until it goes out.
    struct Waiting: Codable, Equatable, Sendable {
        let id: String
        let conversation: RoomConversation
        let author: String
        let text: String
        let replyTo: String?
        let at: Int
        let attachments: [RoomAttachment]
    }

    /// More changes than this since a page and the oldest are dropped: the next page,
    /// which every connection reads, brings them back.
    static let mostChanges = 1_000
    /// Only the phone's recoverable history cache is capped. Waiting sends and the
    /// gateway's saved conversation are never trimmed by this policy.
    static let mostHistoryBytes = 8 * 1_024 * 1_024

    let directory: URL

    static func standardDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("room-archive", isDirectory: true)
    }

    func read(_ conversation: RoomConversation) -> Kept? {
        let url = file(conversation)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= Self.mostHistoryBytes,
              let data = try? Data(contentsOf: url), data.count <= Self.mostHistoryBytes else {
            return nil
        }
        return (try? JSONDecoder().decode(Kept.self, from: data))?.bounded()
    }

    func write(_ kept: Kept, for conversation: RoomConversation) {
        guard let data = try? JSONEncoder().encode(kept.bounded()), data.count <= Self.mostHistoryBytes else {
            return
        }
        save(data, to: file(conversation))
    }

    /// What waits for the link, in the order it was said.
    func readWaiting() -> [Waiting] {
        guard let data = try? Data(contentsOf: waitingFile) else {
            return []
        }
        return (try? JSONDecoder().decode([Waiting].self, from: data)) ?? []
    }

    func writeWaiting(_ waiting: [Waiting]) {
        guard !waiting.isEmpty else {
            try? FileManager.default.removeItem(at: waitingFile)
            return
        }
        guard let data = try? JSONEncoder().encode(waiting) else {
            return
        }
        save(data, to: waitingFile)
    }

    /// The assistant's Today card as its gateway last sent it (TodayModel).
    func readToday() -> JSONValue? {
        guard let data = try? Data(contentsOf: todayFile) else {
            return nil
        }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    func writeToday(_ today: JSONValue?) {
        guard let today, today != .null else {
            try? FileManager.default.removeItem(at: todayFile)
            return
        }
        guard let data = try? JSONEncoder().encode(today) else {
            return
        }
        save(data, to: todayFile)
    }

    func forget() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func file(_ conversation: RoomConversation) -> URL {
        directory.appendingPathComponent(conversation.rawValue + ".json")
    }

    private var waitingFile: URL {
        directory.appendingPathComponent("waiting.json")
    }

    private var todayFile: URL {
        directory.appendingPathComponent("today.json")
    }

    private func save(_ data: Data, to file: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try? data.write(to: file, options: .atomic)
        #endif
    }
}

extension RoomArchive.Kept {
    /// The changes since the page with `entries` added, the oldest dropped past the limit.
    func adding(_ entries: [JSONValue]) -> RoomArchive.Kept {
        var kept = self
        kept.changes.append(contentsOf: entries)
        if kept.changes.count > RoomArchive.mostChanges {
            kept.changes.removeFirst(kept.changes.count - RoomArchive.mostChanges)
        }
        return kept.bounded()
    }

    /// Count and byte limits cover many tiny entries and a few huge ones alike. An
    /// upper bound avoids repeatedly encoding megabytes on the main thread.
    func bounded() -> RoomArchive.Kept {
        var result = self
        if case .object(var page) = result.page {
            var messages = page["messages"]?.arrayValue ?? []
            while Self.bytes(.object(page)) > RoomArchive.mostHistoryBytes / 2, !messages.isEmpty {
                messages.removeFirst(max(1, messages.count / 2))
                page["messages"] = .array(messages)
                page["hasMore"] = .bool(true)
                let ids = Set(messages.compactMap { $0["id"]?.stringValue })
                for key in ["reactions", "approvals", "lives", "places", "transcripts"] {
                    if case .some(.object(let values)) = page[key] {
                        page[key] = .object(values.filter { ids.contains($0.key) })
                    }
                }
                if let oldest = messages.compactMap({ $0["rev"]?.intValue }).min() {
                    page["looks"] = .array((page["looks"]?.arrayValue ?? []).filter { ($0["rev"]?.intValue ?? 0) >= oldest })
                } else {
                    page["looks"] = .array([])
                }
            }
            result.page = .object(page)
        }
        var bytes = Self.bytes(result.page) + 64
        var changes: [JSONValue] = []
        for entry in result.changes.suffix(RoomArchive.mostChanges).reversed() {
            let size = Self.bytes(entry) + 1
            guard bytes + size <= RoomArchive.mostHistoryBytes else { break }
            changes.append(entry)
            bytes += size
        }
        result.changes = Array(changes.reversed())
        return result
    }

    private static func bytes(_ value: JSONValue) -> Int {
        switch value {
        case .null, .bool, .number: return 32
        case .string(let text): return text.utf8.count * 6 + 2
        case .array(let values): return 2 + values.reduce(0) { $0 + bytes($1) + 1 }
        case .object(let members):
            return 2 + members.reduce(0) { $0 + $1.key.utf8.count * 6 + 4 + bytes($1.value) }
        }
    }
}
