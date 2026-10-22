// A file's name as one plain name of its own in a folder: what the Share Extension calls
// each thing it copies into a hand-off, and what a message's attachment is called when it
// is shared out of the app.
//
// Compiled into the app, the Share Extension and the Linux tests.

import Foundation

enum PlainFileName {
    /// The longest name kept, in bytes. A phone's file system takes 255, and the gateway
    /// keeps 200 characters of an attachment's name.
    static let longest = 200

    /// `name` with no folder in it, never hidden, "." or "..", at most `longest` bytes, and
    /// different from every name in `taken`, ignoring case as the phone's file system
    /// does, by a number before its extension: "IMG_0001 2.jpeg".
    static func unique(_ name: String, taken: Set<String>) -> String {
        var cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\u{0}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") {
            cleaned.removeFirst()
        }
        let dot = cleaned.lastIndex(of: ".")
        var stem = dot.map { String(cleaned[..<$0]) } ?? cleaned
        let suffix = dot.map { String(cleaned[$0...]) } ?? ""
        if stem.trimmingCharacters(in: .whitespaces).isEmpty {
            stem = "File"
        }
        let lowered = Set(taken.map { $0.lowercased() })
        var number = 1
        while true {
            let counted = number == 1 ? "" : " \(number)"
            var kept = stem
            while (kept + counted + suffix).utf8.count > longest, !kept.isEmpty {
                kept.removeLast()
            }
            let candidate = kept + counted + suffix
            if !lowered.contains(candidate.lowercased()) {
                return candidate
            }
            number += 1
        }
    }

    /// Whether `name` is a file of its own in a folder and nothing more: not a path, not
    /// hidden, not the folder or its parent.
    static func isPlain(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\u{0}")
            && name.utf8.count <= 255
    }
}
