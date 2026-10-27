#if canImport(UIKit)
import SwiftUI
import UIKit
import XCTest
@testable import HouseholdAssistant

@MainActor
final class ComposerEditingTests: XCTestCase {
    func testLongDraftKeepsCaretVisibleAndStillAllowsReadingEarlierLines() async throws {
        for lines in [3, 6] {
            let shown = try await AppWindow.showing(ComposerHarness(maxLines: lines))
            defer { shown.close() }
            let root = try XCTUnwrap(shown.controller(UIViewController.self)?.view)
            let field = try XCTUnwrap(editor(in: root))
            field.becomeFirstResponder()
            for index in 1...14 {
                field.insertText("Line \(index) with enough words to wrap in the input.\n")
                try await settle(root)
                try assertCaretVisible(field)
            }
            XCTAssertTrue(field.isScrollEnabled)
            XCTAssertLessThanOrEqual(field.bounds.height, ceil(try XCTUnwrap(field.font).lineHeight * CGFloat(lines)) + 1)
            XCTAssertGreaterThan(field.contentOffset.y, 0)

            // An ordinary scroll/layout must not drag the reader back to the end.
            field.setContentOffset(.zero, animated: false)
            try await settle(root)
            XCTAssertEqual(field.contentOffset.y, 0, accuracy: 1)

            // Editing an earlier line follows that insertion point, not the draft's end.
            field.selectedRange = NSRange(location: 10, length: 0)
            field.insertText("🏡 café ")
            try await settle(root)
            try assertCaretVisible(field)
            XCTAssertLessThan(field.contentOffset.y, 50)

            field.selectedRange = NSRange(location: 0, length: (field.text as NSString).length)
            field.insertText("Short again")
            try await settle(root)
            XCTAssertFalse(field.isScrollEnabled)
            XCTAssertEqual(field.contentOffset.y, 0, accuracy: 1)
        }
    }

    func testResetKeepsTheSameFieldAndRespectsOpenOrDismissedKeyboard() async throws {
        let state = ComposerState()
        let shown = try await AppWindow.showing(ComposerHarness(maxLines: 6, state: state))
        defer { shown.close() }
        let root = try XCTUnwrap(shown.controller(UIViewController.self)?.view)
        let field = try XCTUnwrap(editor(in: root))
        for keepKeyboard in [true, false] {
            field.becomeFirstResponder()
            field.insertText(String(repeating: "Long draft\n", count: 15))
            try await settle(root)
            if !keepKeyboard { field.resignFirstResponder() }
            state.text = ""
            state.generation += 1
            try await settle(root)
            XCTAssertTrue(editor(in: root) === field, "Send must not recreate the editor")
            XCTAssertEqual(field.isFirstResponder, keepKeyboard)
            XCTAssertTrue(field.text.isEmpty)
            XCTAssertFalse(field.isScrollEnabled)
            XCTAssertEqual(field.contentOffset.y, 0, accuracy: 1)
            field.becomeFirstResponder()
            field.insertText("Next draft")
            try await settle(root)
            XCTAssertEqual(state.text, "Next draft", "the sent draft must not reappear")
            field.selectedRange = NSRange(location: 0, length: (field.text as NSString).length)
            field.insertText("")
        }
    }

    private func assertCaretVisible(_ field: UITextView, file: StaticString = #filePath, line: UInt = #line) throws {
        let range = try XCTUnwrap(field.selectedTextRange, file: file, line: line)
        let caret = field.caretRect(for: range.end)
        XCTAssertGreaterThanOrEqual(caret.minY, field.bounds.minY - 1, file: file, line: line)
        XCTAssertLessThanOrEqual(caret.maxY, field.bounds.maxY + 1, file: file, line: line)
    }

    private func settle(_ root: UIView) async throws {
        try await Task.sleep(for: .milliseconds(100))
        root.layoutIfNeeded()
    }

    private func editor(in root: UIView) -> ImagePasteTextView? {
        (root as? ImagePasteTextView) ?? root.subviews.lazy.compactMap { self.editor(in: $0) }.first
    }
}

@MainActor @Observable
private final class ComposerState {
    var text = ""
    var focused = false
    var generation = 0
}

private struct ComposerHarness: View {
    let maxLines: Int
    @State var state = ComposerState()

    var body: some View {
        @Bindable var state = state
        ComposerTextView(text: $state.text, isFocused: $state.focused,
                         maxLines: maxLines, resetGeneration: state.generation, onPasteImages: { _ in })
            .frame(width: 240)
            .padding()
    }
}
#endif
