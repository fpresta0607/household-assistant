#if canImport(UIKit)
// An assistant's reply never grows its type (CFO notes section 21): every heading level,
// bold, italic, link, bulleted and numbered list, block quote, code block and table in
// RoomMarkdown's look is at most the body's size, so a long scripture or devotional reply
// reads at one size, with headings marked by weight.

import UIKit
import XCTest
@testable import HouseholdAssistant

@MainActor
final class RoomMarkdownSizeTests: XCTestCase {
    private let config = RoomMarkdown.config

    private var body: CGFloat {
        config.paragraphStyle.textFonts.normal.pointSize
    }

    func testNoHeadingIsLargerThanTheBody() {
        let headings = config.headingStyle
        let levels = [
            ("h1", headings.h1Font), ("h2", headings.h2Font), ("h3", headings.h3Font),
            ("h4", headings.h4Font), ("h5", headings.h5Font), ("h6", headings.h6Font),
        ]
        for (level, fonts) in levels {
            // Act
            let sizes = [fonts.normal, fonts.italic, fonts.bold, fonts.boldItalic].compactMap { $0?.pointSize }

            // Assert
            XCTAssertEqual(sizes.count, 4, "\(level) has every variant")
            for size in sizes {
                XCTAssertLessThanOrEqual(size, body, "\(level) at \(size) over the body's \(body)")
            }
            XCTAssertEqual(fonts.normal, config.paragraphStyle.textFonts.bold, "\(level) is the body's semibold")
        }
    }

    func testNoBlockOrRunIsLargerThanTheBody() {
        // Arrange
        let paragraph = config.paragraphStyle.textFonts
        let numbered = config.orderedListStyle.textFonts
        let quote = config.blockQuoteStyle.textFonts
        let code = config.codeBlockConfig.codeTextFonts
        let codeLabel = config.codeBlockConfig.chromeTextFonts
        let table = config.tableStyle.textFonts
        // The renderer draws a bulleted item's words in the paragraph's fonts, beside a dot
        // it draws as a picture, so the paragraph's fonts are a bulleted list's too.
        let cases: [(name: String, fonts: [UIFont?])] = [
            ("paragraph and bulleted list", [paragraph.normal, paragraph.italic, paragraph.bold, paragraph.boldItalic]),
            ("numbered list", [numbered.normal, numbered.italic, numbered.bold, numbered.boldItalic]),
            ("block quote", [quote.normal, quote.italic, quote.bold, quote.boldItalic]),
            ("code block", [code.normal, code.italic, code.bold, code.boldItalic]),
            ("code block label", [codeLabel.normal, codeLabel.italic, codeLabel.bold, codeLabel.boldItalic]),
            ("table", [table.normal, table.italic, table.bold, table.boldItalic]),
            ("link", [config.inlineStyle.linkTextFont]),
            ("inline code", [config.inlineStyle.codeTextFont]),
        ]
        for (name, fonts) in cases {
            // Act
            let sizes = fonts.compactMap { $0?.pointSize }

            // Assert
            XCTAssertFalse(sizes.isEmpty, "\(name) has a font")
            for size in sizes {
                XCTAssertLessThanOrEqual(size, body, "\(name) at \(size) over the body's \(body)")
            }
        }
    }
}
#endif
