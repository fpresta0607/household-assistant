#if canImport(UIKit)
import SwiftUI
import UIKit
import XCTest
@testable import HouseholdAssistant

@MainActor
final class MessageSelectionTests: XCTestCase {
    func testNativeCopyUsesOnlyTheSelectedUnicodePassage() {
        let saved = UIPasteboard.general.items
        defer { UIPasteboard.general.items = saved }
        let text = "Bring 🏡 and café.\nKeep the rest of this message."
        let view = MessageTextView()
        view.text = text
        view.selectedRange = (text as NSString).range(of: "🏡 and café")
        view.copy(nil)
        XCTAssertEqual(UIPasteboard.general.string, "🏡 and café")
        XCTAssertEqual(view.text, text)
        XCTAssertFalse(view.isEditable)
    }

    func testMessageMenuYieldsToNativeSelectionHandles() async throws {
        let shown = try await AppWindow.showing(
            InlineMessageText(text: NSAttributedString(string: "Bring the garden notebook.", attributes: [
                .font: UIFont.systemFont(ofSize: 17)
            ]))
            .frame(width: 260)
        )
        defer { shown.close() }
        let root = try XCTUnwrap(shown.controller(UIViewController.self)?.view)
        let view = try XCTUnwrap(textView(in: root))
        let bubbleHold = UILongPressGestureRecognizer()
        root.addGestureRecognizer(bubbleHold)
        let selectionHold = UILongPressGestureRecognizer()
        view.addGestureRecognizer(selectionHold)
        let coordinator = MessageMenuGesture.Coordinator()
        XCTAssertTrue(coordinator.gestureRecognizer(bubbleHold, shouldBeRequiredToFailBy: selectionHold))
        XCTAssertTrue(view.becomeFirstResponder())
        view.selectedRange = (view.text as NSString).range(of: "garden")
        let point = root.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), from: view)
        XCTAssertTrue(MessageMenuGesture.Coordinator.hasSelection(near: point, in: root))
        XCTAssertFalse(coordinator.gestureRecognizer(bubbleHold, shouldBeRequiredToFailBy: selectionHold))
        view.resignFirstResponder()
        XCTAssertFalse(MessageMenuGesture.Coordinator.hasSelection(near: point, in: root))
        XCTAssertTrue(view.selectedTextRange == nil || view.selectedTextRange?.isEmpty == true)
    }

    private func textView(in root: UIView) -> MessageTextView? {
        (root as? MessageTextView) ?? root.subviews.lazy.compactMap { self.textView(in: $0) }.first
    }
}
#endif
