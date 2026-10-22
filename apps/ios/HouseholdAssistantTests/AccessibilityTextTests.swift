#if canImport(UIKit)
import SwiftUI
import UIKit
import XCTest
@testable import HouseholdAssistant

@MainActor
final class AccessibilityTextTests: XCTestCase {
    func testEveryReadingSizeKeepsEmphasisAndScalesEveryMarkdownFont() {
        let normal = ReadingStyle.standard.config.paragraphStyle.textFonts.normal
        for size in DynamicTypeSize.allCases {
            let regular = ReadingStyle(size: size).config
            let bold = ReadingStyle(size: size, isBold: true).config
            let body = bold.paragraphStyle.textFonts
            XCTAssertGreaterThan(weight(body.normal), weight(regular.paragraphStyle.textFonts.normal))
            XCTAssertGreaterThan(weight(body.bold!), weight(body.normal), "emphasis survives accessibility bold")
            XCTAssertTrue(body.italic!.fontDescriptor.symbolicTraits.contains(.traitItalic))
            XCTAssertTrue(body.boldItalic!.fontDescriptor.symbolicTraits.contains(.traitItalic))
            XCTAssertEqual(bold.inlineStyle.linkTextFont.pointSize, body.normal.pointSize)
            XCTAssertEqual(bold.headingStyle.h1Font.normal.pointSize, body.normal.pointSize)
            XCTAssertLessThanOrEqual(bold.tableStyle.textFonts.normal.pointSize, body.normal.pointSize)
            XCTAssertLessThanOrEqual(bold.inlineStyle.codeTextFont.pointSize, body.normal.pointSize)
            XCTAssertGreaterThanOrEqual(body.preferredLineHeight!, body.normal.lineHeight)
            if size > .large { XCTAssertGreaterThan(body.normal.pointSize, normal.pointSize) }
        }
    }

    func testLiveBoldAndSizeChangesReflowTheThreadWithoutLosingTheDraftOrSelection() async throws {
        FixtureGateway.forgetPersistedState()
        defer { FixtureGateway.forgetPersistedState() }
        let gateway = FixtureGateway()
        await gateway.connect()
        gateway.model.path = [.direct]
        let shown = try await AppWindow.showing(RootView().environment(gateway.model))
        defer { shown.close() }
        try await Task.sleep(for: .seconds(1))
        let root = try XCTUnwrap(shown.controller(UIViewController.self)?.view)
        let input = try XCTUnwrap(editor(in: root))
        input.becomeFirstResponder()
        input.insertText("Morning draft stays editable.")
        let point = try XCTUnwrap(input.position(from: input.beginningOfDocument, offset: 8))
        input.selectedTextRange = input.textRange(from: point, to: point)
        let original = try XCTUnwrap(paragraphs(in: root).last)
        let words = original.text
        let before = try font(in: original)

        // A row redraws once its words are parsed again in the new style, off the main
        // thread, which took from 0.2 to 1.5 seconds on GitHub's Macs, so a fixed second
        // read the old font some of the time (issue 27). Each step waits for what it checks.
        gateway.model.settings.isTextBold = true
        await gateway.eventually("the row redraws in Bold Text") {
            let row = self.paragraphs(in: root).first { $0.text == words }
            return row.flatMap { try? self.font(in: $0) }.map { self.weight($0) > self.weight(before) } ?? false
        }
        let bold = try XCTUnwrap(paragraphs(in: root).first { $0.text == words })
        XCTAssertGreaterThan(weight(try font(in: bold)), weight(before), "a visible cached row must redraw")

        gateway.model.settings.textSize = .xxxLarge
        await gateway.eventually("the row redraws larger, with room for its words") {
            guard let row = self.paragraphs(in: root).first(where: { $0.text == words }),
                  let shown = try? self.font(in: row) else { return false }
            return shown.pointSize > before.pointSize
                && row.bounds.height + 2 >= row.sizeThatFits(CGSize(width: row.bounds.width, height: .greatestFiniteMagnitude)).height
        }
        let larger = try XCTUnwrap(paragraphs(in: root).first { $0.text == words })
        XCTAssertGreaterThan(try font(in: larger).pointSize, before.pointSize)
        XCTAssertGreaterThan(weight(try font(in: larger)), weight(before), "larger text must keep Bold Text")
        XCTAssertLessThanOrEqual(larger.bounds.width, root.bounds.width)
        XCTAssertGreaterThanOrEqual(larger.bounds.height + 2, larger.sizeThatFits(CGSize(width: larger.bounds.width, height: .greatestFiniteMagnitude)).height)
        XCTAssertTrue(editor(in: root) === input, "changing type must not recreate the editor")
        let selection = try XCTUnwrap(input.selectedTextRange)
        XCTAssertEqual(input.offset(from: input.beginningOfDocument, to: selection.start), 8)
        input.insertText("updated ")
        let range = try XCTUnwrap(input.textRange(from: input.beginningOfDocument, to: input.endOfDocument))
        XCTAssertEqual(input.text(in: range), "Morning updated draft stays editable.")
    }

    func testIPhoneReadingPreferencesReachHostedRepliesWithoutAnAppOverride() async throws {
        FixtureGateway.forgetPersistedState()
        defer { FixtureGateway.forgetPersistedState() }
        let gateway = FixtureGateway()
        let words = "Reading from my iPhone."
        gateway.room.say(words, by: "corey", in: .direct)
        await gateway.connect()
        gateway.model.path = [.direct]
        XCTAssertEqual(gateway.model.settings.textSize, .likeIPhone)
        XCTAssertFalse(gateway.model.settings.isTextBold)
        let shown = try await AppWindow.showing(
            RootView().environment(gateway.model)
                .environment(\.dynamicTypeSize, .accessibility3)
                .environment(\.legibilityWeight, .bold)
        )
        defer { shown.close() }
        let root = try XCTUnwrap(shown.controller(UIViewController.self)?.view)
        await gateway.eventually("the assistant's reply is drawn") {
            self.paragraphs(in: root).contains { $0.text == words }
        }
        let paragraph = try XCTUnwrap(paragraphs(in: root).first { $0.text == words })
        let actual = try font(in: paragraph)
        let expected = ReadingStyle(size: .accessibility3, isBold: true).config.paragraphStyle.textFonts.normal
        XCTAssertEqual(actual.pointSize, expected.pointSize)
        XCTAssertGreaterThanOrEqual(weight(actual), weight(expected))
    }

    private func font(in text: UITextView) throws -> UIFont {
        try XCTUnwrap(text.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
    }

    private func weight(_ font: UIFont) -> CGFloat {
        (font.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any])?[.weight] as? CGFloat ?? 0
    }

    private func views(in root: UIView) -> [UIView] {
        [root] + root.subviews.flatMap { views(in: $0) }
    }

    private func paragraphs(in root: UIView) -> [UITextView] {
        views(in: root).compactMap { $0 as? UITextView }.filter {
            !$0.isEditable && $0.attributedText.length > 0 && $0.window != nil
        }
    }

    private func editor(in root: UIView) -> (UIView & UITextInput)? {
        for view in views(in: root) {
            if let field = view as? UITextView, field.isEditable { return field }
            if let field = view as? UITextField, field.isEnabled { return field }
        }
        return nil
    }
}
#endif
