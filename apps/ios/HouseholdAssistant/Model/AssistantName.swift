// A name the assistant can be given: 1 to 24 letters, spaces, hyphens and apostrophes,
// the rule the gateway holds a change to. Checked here first so Save waits for a name the
// gateway will take, and so the signed value is always one line.

import Foundation

enum AssistantName {
    static let longest = 24

    /// What was typed, without the spaces at its ends, and with the keyboard's curly
    /// apostrophe as the plain one.
    static func cleaned(_ typed: String) -> String {
        typed.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\u{2019}", with: "'")
    }

    static func isValid(_ name: String) -> Bool {
        (1...longest).contains(name.count)
            && name.contains(where: \.isLetter)
            && name.allSatisfy { $0.isLetter || $0 == " " || $0 == "-" || $0 == "'" }
    }
}
