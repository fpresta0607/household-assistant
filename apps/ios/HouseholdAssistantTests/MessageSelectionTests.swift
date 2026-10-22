#if canImport(UIKit)
import UIKit
import XCTest
@testable import HouseholdAssistant

@MainActor
final class MessageSelectionTests: XCTestCase {
    func testSelectionReturnsOnlyTheChosenUnicodePassageAndLeavesTheMessageIntact() {
        let text = "Bring 🏡 and café.\nKeep the rest of this message."
        let view = UITextView()
        view.text = text
        view.isEditable = false
        var selection = ""
        let coordinator = SelectableMessageText.Coordinator { selection = $0 }
        view.selectedRange = (text as NSString).range(of: "🏡 and café")
        coordinator.textViewDidChangeSelection(view)
        XCTAssertEqual(selection, "🏡 and café")
        XCTAssertEqual(view.text, text)
        view.selectedRange = NSRange(location: 0, length: 0)
        coordinator.textViewDidChangeSelection(view)
        XCTAssertTrue(selection.isEmpty)
    }
}
#endif
