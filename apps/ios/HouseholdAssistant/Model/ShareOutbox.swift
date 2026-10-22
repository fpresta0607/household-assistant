// The App Group folder the Share Extension leaves hand-offs in for the app (ShareHandoff):
// a folder each, named by its id, holding its files and `handoff.json`.
//
// The extension fills a draft folder as the sheet opens and renames it once the person
// taps Send, so the app never reads one half written. The app sends each, then removes
// it. Two processes share the folder, so what the app reads back is checked before it is
// sent: a hand-off that does not hold together is thrown away rather than tried at every
// start, and a draft nobody finished is cleared after an hour.
//
// Compiled into the app, the Share Extension and the Linux tests.

import Foundation

struct ShareOutbox: Sendable {
    enum Refusal: Error {
        /// Not an id a message can be named by, so not a folder of the outbox either.
        case notAnId
        /// A file the hand-off names is not in its draft, or is no plain name.
        case missingFile(String)
    }

    let folder: URL

    static let manifest = "handoff.json"
    /// A draft left this long was abandoned: the extension was closed half way.
    static let abandonedAfter: TimeInterval = 60 * 60
    private static let draftSuffix = ".draft"
    /// The gateway names a message by one letter, a dash and up to 78 more, so the id it
    /// is sent under fits.
    private static let idCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")

    init(folder: URL) {
        self.folder = folder
    }

    /// A folder for a new hand-off's files, which nothing reads until it is posted.
    func draft(_ id: String) throws -> URL {
        guard Self.isId(id) else {
            throw Refusal.notAnId
        }
        let draft = draftFolder(id)
        try FileManager.default.createDirectory(at: draft, withIntermediateDirectories: true)
        return draft
    }

    /// Writes the hand-off into its draft and names it ready for the app.
    func post(_ handoff: ShareHandoff) throws {
        guard Self.isId(handoff.id) else {
            throw Refusal.notAnId
        }
        let draft = draftFolder(handoff.id)
        if let missing = handoff.items.first(where: { !Self.isItem($0.file, in: draft) }) {
            throw Refusal.missingFile(missing.file)
        }
        try JSONEncoder().encode(handoff).write(to: draft.appendingPathComponent(Self.manifest), options: .atomic)
        try FileManager.default.moveItem(at: draft, to: readyFolder(handoff.id))
    }

    /// Throws away a draft the person cancelled.
    func discard(_ id: String) {
        guard Self.isId(id) else {
            return
        }
        try? FileManager.default.removeItem(at: draftFolder(id))
    }

    /// Every hand-off ready to send, oldest first.
    func pending(now: Date = Date()) -> [ShareHandoff] {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else {
            return []
        }
        var ready: [ShareHandoff] = []
        for name in names {
            let entry = folder.appendingPathComponent(name, isDirectory: true)
            if name.hasSuffix(Self.draftSuffix) {
                let touched = try? fileManager.attributesOfItem(atPath: entry.path)[.modificationDate] as? Date
                if let touched, now.timeIntervalSince(touched) > Self.abandonedAfter {
                    try? fileManager.removeItem(at: entry)
                }
                continue
            }
            if let handoff = readable(name, at: entry) {
                ready.append(handoff)
            } else {
                try? fileManager.removeItem(at: entry)
            }
        }
        return ready.sorted { first, second in
            first.at == second.at ? first.id < second.id : first.at < second.at
        }
    }

    func file(_ item: ShareHandoff.Item, of handoff: ShareHandoff) -> URL {
        readyFolder(handoff.id).appendingPathComponent(item.file)
    }

    /// Takes a sent hand-off away with its files.
    func remove(_ id: String) {
        guard Self.isId(id) else {
            return
        }
        try? FileManager.default.removeItem(at: readyFolder(id))
    }

    /// Everything, ready or not: what was shared for a gateway this phone no longer
    /// pairs with goes nowhere.
    func removeAll() {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Private

    private func draftFolder(_ id: String) -> URL {
        folder.appendingPathComponent(id + Self.draftSuffix, isDirectory: true)
    }

    private func readyFolder(_ id: String) -> URL {
        folder.appendingPathComponent(id, isDirectory: true)
    }

    /// The hand-off in the folder called `name`, when it is the one the folder is named
    /// for and every file it names is in it.
    private func readable(_ name: String, at entry: URL) -> ShareHandoff? {
        guard
            Self.isId(name),
            let data = try? Data(contentsOf: entry.appendingPathComponent(Self.manifest)),
            let handoff = try? JSONDecoder().decode(ShareHandoff.self, from: data),
            handoff.id == name,
            handoff.items.allSatisfy({ Self.isItem($0.file, in: entry) })
        else {
            return nil
        }
        return handoff
    }

    private static func isId(_ id: String) -> Bool {
        guard let first = id.first, first != "-" else {
            return false
        }
        return (8...78).contains(id.count) && id.allSatisfy(idCharacters.contains)
    }

    /// A file of the hand-off's own, there in its folder: never a path out of it, and
    /// never the hand-off itself.
    private static func isItem(_ name: String, in folder: URL) -> Bool {
        PlainFileName.isPlain(name) && name != manifest
            && FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
    }
}
