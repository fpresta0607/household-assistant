import XCTest
@testable import HouseholdAssistant

final class ScriptureCardTests: XCTestCase {
    private func decode(_ fields: String = "") throws -> ScriptureCard {
        let json = #"{"reference":"John 3:16-17","translation":"BSB","verses":[{"n":16,"text":"Verse text"},{"n":17,"text":"Verse text"}]"# + fields + "}"
        return try JSONDecoder().decode(ScriptureCard.self, from: Data(json.utf8))
    }

    func testOlderCardsWithoutLinksOpenTheSamePassage() throws {
        let expected = URL(string: "https://www.bible.com/bible/3034/JHN.3.16-17.BSB")
        for field in ["", #","link":null"#, ",\"link\":\"\"", #","link":"   ""#] {
            XCTAssertEqual(try decode(field).link, expected, field)
        }
        XCTAssertEqual(try decode(#","author":"corey""#).link, try decode(#","author":"denise""#).link)
    }

    func testAnExplicitLinkIsPreservedAndUnsafeLinksAreStillRefused() throws {
        XCTAssertEqual(try decode(#","link":"https://www.bible.com/bible/1/JHN.3.16-17.KJV""#).link,
                       URL(string: "https://www.bible.com/bible/1/JHN.3.16-17.KJV"))
        for link in ["http://www.bible.com/bible/3034/JHN.3.16.BSB", "javascript:alert(1)", "file:///tmp/a"] {
            XCTAssertThrowsError(try decode(",\"link\":\"\(link)\""))
        }
    }

    func testReferenceSpellingsAndRangesReachTheirOwnBooks() {
        let cases = [
            ("Psalm 23:1–6", "PSA.23.1-6"), ("Psalms 23", "PSA.23"),
            ("1 Corinthians 13:4-7", "1CO.13.4-7"), ("I Samuel 2:3", "1SA.2.3"),
            ("II Tim. 1:7", "2TI.1.7"), ("III John 1:2", "3JN.1.2"),
            ("Phil 4:13", "PHP.4.13"), ("Song of Songs 2:1", "SNG.2.1"),
            ("Genesis 1:1", "GEN.1.1"), ("Revelation 22:21", "REV.22.21"),
            (" John 3 : 16 - 17 ", "JHN.3.16-17"), ("JHN 3.16", "JHN.3.16"),
        ]
        for (reference, passage) in cases {
            XCTAssertEqual(BiblePassageLink.url(reference: reference, translation: "BSB")?.absoluteString,
                           "https://www.bible.com/bible/3034/\(passage).BSB", reference)
        }
    }

    func testTheTranslationIsPreservedRatherThanSilentlyChanged() {
        for (translation, path) in [("BSB", "3034/JHN.3.16.BSB"), ("Berean Standard Bible", "3034/JHN.3.16.BSB"),
                                    (" kjv ", "1/JHN.3.16.KJV"), ("ASV", "12/JHN.3.16.ASV")] {
            XCTAssertEqual(BiblePassageLink.url(reference: "John 3:16", translation: translation)?.absoluteString,
                           "https://www.bible.com/bible/\(path)")
        }
        XCTAssertNil(BiblePassageLink.url(reference: "John 3:16", translation: "Unknown translation"))
    }

    func testAnUnrecognizedOrMalformedReferenceIsNeverGuessed() {
        for reference in ["", "Made Up 3:16", "John 0:16", "John 22:16", "John 3:0", "John 3:17-16",
                          "John 3:999", "John 3:16-4:2", "John 3:16; Romans 8:1", "John 3:16 trailing words"] {
            XCTAssertNil(BiblePassageLink.url(reference: reference, translation: "BSB"), reference)
        }
    }
}
