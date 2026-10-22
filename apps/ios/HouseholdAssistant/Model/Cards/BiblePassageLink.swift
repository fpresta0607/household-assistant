// A missing link must not make the same passage behave differently for two assistants.
// Resolve recognized references locally, including cards already stored on the phone.
// Explicit card links still take precedence. Unknown references or translations are not
// guessed, and no network call or model request is needed to build a link.

import Foundation

enum BiblePassageLink {
    private static let versions = [
        "BSB": (3034, "BSB"), "BEREAN STANDARD BIBLE": (3034, "BSB"),
        "KJV": (1, "KJV"), "KING JAMES VERSION": (1, "KJV"),
        "ASV": (12, "ASV"), "AMERICAN STANDARD VERSION": (12, "ASV"),
    ]
    // USFM code, chapter count, full name and the scripture tool's accepted short forms.
    private static let entries: [(String, Int, [String])] = [
        ("GEN", 50, ["Genesis", "Gen"]), ("EXO", 40, ["Exodus", "Exod", "Exo"]),
        ("LEV", 27, ["Leviticus", "Lev"]), ("NUM", 36, ["Numbers", "Num"]),
        ("DEU", 34, ["Deuteronomy", "Deut", "Deu"]), ("JOS", 24, ["Joshua", "Josh", "Jos"]),
        ("JDG", 21, ["Judges", "Judg", "Jdg"]), ("RUT", 4, ["Ruth", "Rut"]),
        ("1SA", 31, ["1 Samuel", "1 Sam", "1Sa"]), ("2SA", 24, ["2 Samuel", "2 Sam", "2Sa"]),
        ("1KI", 22, ["1 Kings", "1 Kgs", "1Ki"]), ("2KI", 25, ["2 Kings", "2 Kgs", "2Ki"]),
        ("1CH", 29, ["1 Chronicles", "1 Chr", "1Ch"]), ("2CH", 36, ["2 Chronicles", "2 Chr", "2Ch"]),
        ("EZR", 10, ["Ezra", "Ezr"]), ("NEH", 13, ["Nehemiah", "Neh"]),
        ("EST", 10, ["Esther", "Esth", "Est"]), ("JOB", 42, ["Job"]),
        ("PSA", 150, ["Psalms", "Psalm", "Ps", "Psa"]), ("PRO", 31, ["Proverbs", "Prov", "Pro"]),
        ("ECC", 12, ["Ecclesiastes", "Eccl", "Ecc"]),
        ("SNG", 8, ["Song of Solomon", "Song of Songs", "Song", "Canticles", "Sng"]),
        ("ISA", 66, ["Isaiah", "Isa"]), ("JER", 52, ["Jeremiah", "Jer"]),
        ("LAM", 5, ["Lamentations", "Lam"]), ("EZK", 48, ["Ezekiel", "Ezek", "Ezk"]),
        ("DAN", 12, ["Daniel", "Dan"]), ("HOS", 14, ["Hosea", "Hos"]),
        ("JOL", 3, ["Joel", "Jol"]), ("AMO", 9, ["Amos", "Amo"]),
        ("OBA", 1, ["Obadiah", "Obad", "Oba"]), ("JON", 4, ["Jonah", "Jon"]),
        ("MIC", 7, ["Micah", "Mic"]), ("NAM", 3, ["Nahum", "Nah", "Nam"]),
        ("HAB", 3, ["Habakkuk", "Hab"]), ("ZEP", 3, ["Zephaniah", "Zeph", "Zep"]),
        ("HAG", 2, ["Haggai", "Hag"]), ("ZEC", 14, ["Zechariah", "Zech", "Zec"]),
        ("MAL", 4, ["Malachi", "Mal"]), ("MAT", 28, ["Matthew", "Matt", "Mat"]),
        ("MRK", 16, ["Mark", "Mrk"]), ("LUK", 24, ["Luke", "Luk"]),
        ("JHN", 21, ["John", "Jhn", "Jn"]), ("ACT", 28, ["Acts", "Act"]),
        ("ROM", 16, ["Romans", "Rom"]), ("1CO", 16, ["1 Corinthians", "1 Cor", "1Co"]),
        ("2CO", 13, ["2 Corinthians", "2 Cor", "2Co"]), ("GAL", 6, ["Galatians", "Gal"]),
        ("EPH", 6, ["Ephesians", "Eph"]), ("PHP", 4, ["Philippians", "Phil", "Php"]),
        ("COL", 4, ["Colossians", "Col"]), ("1TH", 5, ["1 Thessalonians", "1 Thess", "1Th"]),
        ("2TH", 3, ["2 Thessalonians", "2 Thess", "2Th"]), ("1TI", 6, ["1 Timothy", "1 Tim", "1Ti"]),
        ("2TI", 4, ["2 Timothy", "2 Tim", "2Ti"]), ("TIT", 3, ["Titus", "Tit"]),
        ("PHM", 1, ["Philemon", "Phlm", "Phm"]), ("HEB", 13, ["Hebrews", "Heb"]),
        ("JAS", 5, ["James", "Jas"]), ("1PE", 5, ["1 Peter", "1 Pet", "1Pe"]),
        ("2PE", 3, ["2 Peter", "2 Pet", "2Pe"]), ("1JN", 5, ["1 John", "1John", "1Jn"]),
        ("2JN", 1, ["2 John", "2John", "2Jn"]), ("3JN", 1, ["3 John", "3John", "3Jn"]),
        ("JUD", 1, ["Jude", "Jud"]), ("REV", 22, ["Revelation", "Revelation of John", "Rev"]),
    ]

    static func url(reference: String, translation: String) -> URL? {
        let version = translation.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let (versionID, suffix) = versions[version] else { return nil }
        let text = reference.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{2013}", with: "-")
            .replacingOccurrences(of: "\u{2014}", with: "-")
        let pattern = #"^(.+?)\s+([1-9][0-9]{0,2})(?:\s*[:.]\s*([1-9][0-9]{0,2})(?:\s*-\s*([1-9][0-9]{0,2}))?)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func part(_ index: Int) -> String? {
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
        guard let name = part(1), let chapterText = part(2), let chapter = Int(chapterText),
              let book = entries.first(where: { $0.2.contains { normalized($0) == normalized(name) } }),
              chapter <= book.1 else { return nil }
        var passage = "\(book.0).\(chapter)"
        if let firstText = part(3), let first = Int(firstText) {
            let last = part(4).flatMap(Int.init) ?? first
            guard first <= last, last <= 176 else { return nil }
            passage += ".\(first)" + (last == first ? "" : "-\(last)")
        }
        return URL(string: "https://www.bible.com/bible/\(versionID)/\(passage).\(suffix)")
    }

    private static func normalized(_ name: String) -> String {
        var name = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for (roman, digit) in [("iii ", "3 "), ("ii ", "2 "), ("i ", "1 ")] where name.hasPrefix(roman) {
            name = digit + name.dropFirst(roman.count)
            break
        }
        return name.filter { $0.isLetter || $0.isNumber }
    }
}
