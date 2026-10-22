import Foundation

/// A saved message read as words, in requests small enough for the existing speech API.
/// The gateway counts UTF-16 units, so emoji and non-Latin text cannot exceed its limit.
enum MessageSpeechText {
    static let maximumUnits = 400

    static func chunks(_ text: String) -> [String] {
        let words = text.split(whereSeparator: \.isWhitespace)
        var chunks: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty { chunks.append(current); current = "" }
        }
        for word in words {
            if current.utf16.count + (current.isEmpty ? 0 : 1) + word.utf16.count <= maximumUnits {
                if !current.isEmpty { current += " " }
                current += word
                continue
            }
            flush()
            // Most words fit whole. An unusually long URL or unbroken passage is split
            // at Unicode scalar boundaries, never inside a surrogate pair.
            for scalar in word.unicodeScalars {
                let part = String(scalar)
                if current.utf16.count + part.utf16.count > maximumUnits { flush() }
                current += part
            }
        }
        flush()
        return chunks
    }
}
