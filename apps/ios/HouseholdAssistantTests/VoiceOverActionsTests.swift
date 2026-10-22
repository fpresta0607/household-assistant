#if canImport(UIKit)
// VoiceOver reaches a message's menu without the long-press: Reply, React and, for a
// message with words, Copy are actions of the very element it lands on, and Copy copies
// the words as the menu does.
// The build 14 audit found the actions on the stack around the bubble, and Copy reachable
// only through React.

import SwiftUI
import UIKit
import XCTest
@testable import HouseholdAssistant

@MainActor
final class VoiceOverActionsTests: XCTestCase {
    private var shown: AppWindow?

    override func setUp() async throws {
        FixtureGateway.forgetPersistedState()
    }

    override func tearDown() async throws {
        shown?.close()
        shown = nil
        FixtureGateway.forgetPersistedState()
    }

    /// What VoiceOver landed on in the last conversation looked at, by identifier or label,
    /// for a failure to say.
    private var landedOn: [String] = []

    /// The messages VoiceOver lands on in both conversations.
    private func messagesVoiceOverFinds() async throws -> [NSObject] {
        let gateway = FixtureGateway()
        await gateway.connect()
        let shown = try await AppWindow.showing(RootView().environment(gateway.model), readByAccessibility: true)
        self.shown = shown
        var found: [NSObject] = []
        for conversation in RoomConversation.allCases {
            gateway.model.path = [conversation]
            try await Task.sleep(for: .seconds(1.5))
            let elements = shown.accessibilityElements()
            landedOn = elements.prefix(30).map { element in
                Self.identifier(of: element) ?? element.accessibilityLabel ?? "?"
            }
            found += elements.filter { Self.identifier(of: $0) == "room.message" }
            gateway.model.path = []
            try await Task.sleep(for: .seconds(1))
        }
        return found
    }

    /// An element's accessibility identifier. SwiftUI's elements answer it without saying
    /// they conform to UIAccessibilityIdentification, so it is asked for by its getter.
    private static func identifier(of element: NSObject) -> String? {
        let getter = #selector(getter: UIAccessibilityIdentification.accessibilityIdentifier)
        guard element.responds(to: getter) else {
            return nil
        }
        return element.perform(getter)?.takeUnretainedValue() as? String
    }

    func testEveryMessageOffersReplyAndReactAndOnesWithWordsCopyWhereVoiceOverLands() async throws {
        // Arrange and act
        let messages = try await messagesVoiceOverFinds()

        // Assert
        XCTAssertFalse(messages.isEmpty, "VoiceOver found no message, only \(landedOn)")
        for message in messages {
            let actions = (message.accessibilityCustomActions ?? []).map(\.name)
            XCTAssertTrue(["Reply", "React"].allSatisfy(actions.contains), "a message offers only \(actions)")
        }
        XCTAssertTrue(
            messages.contains { ($0.accessibilityCustomActions ?? []).contains { $0.name == "Copy" } },
            "no message with words offers Copy"
        )
    }

    func testCopyFromVoiceOverCopiesTheWordsWithoutCardSyntax() async throws {
        // Arrange
        let messages = try await messagesVoiceOverFinds()
        let copies = messages.compactMap { message in
            message.accessibilityCustomActions?.first { $0.name == "Copy" }
        }
        XCTAssertFalse(copies.isEmpty, "no message offers Copy among \(messages.count) messages, VoiceOver landed on \(landedOn)")

        for copy in copies {
            UIPasteboard.general.string = ""

            // Act
            if let handler = copy.actionHandler {
                _ = handler(copy)
            } else if let target = copy.target as? NSObject {
                _ = target.perform(copy.selector, with: copy)
            }

            // Assert
            let copied = UIPasteboard.general.string ?? ""
            XCTAssertFalse(copied.isEmpty, "Copy copied nothing")
            XCTAssertFalse(copied.contains("steward-card"), "Copy handed over a card's JSON")
        }
    }
}
#endif
