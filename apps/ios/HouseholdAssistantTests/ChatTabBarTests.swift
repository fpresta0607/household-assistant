#if canImport(UIKit)
// The tab bar is gone while a chat is open and back on Chats (CFO notes section 8), read
// off the tab bar controller iOS draws, with each chat opened the way its pin opens it.
// Before the bar was hidden from the Chats tab's own content, both chats kept it under
// their composer while each asked for it to be hidden from inside the NavigationStack.

import SwiftUI
import UIKit
import XCTest
@testable import HouseholdAssistant

@MainActor
final class ChatTabBarTests: XCTestCase {
    private var shown: AppWindow?

    override func setUp() async throws {
        FixtureGateway.forgetPersistedState()
    }

    override func tearDown() async throws {
        shown?.close()
        shown = nil
        FixtureGateway.forgetPersistedState()
    }

    func testAnOpenChatHasNoTabBarAndChatsHasItBack() async throws {
        for conversation in RoomConversation.allCases {
            // Arrange
            let gateway = FixtureGateway()
            await gateway.connect()
            shown?.close()
            let shown = try await AppWindow.showing(RootView().environment(gateway.model))
            self.shown = shown
            let tabs = try XCTUnwrap(shown.controller(UITabBarController.self), "no tab bar controller on screen")
            XCTAssertFalse(tabs.isTabBarHidden, "Chats opened with no tab bar")

            // Act
            gateway.model.path = [conversation]
            try await Task.sleep(for: .seconds(1.5))
            let isHiddenInChat = tabs.isTabBarHidden
            gateway.model.path = []
            try await Task.sleep(for: .seconds(1.5))

            // Assert
            XCTAssertTrue(isHiddenInChat, "the tab bar shows in \(conversation)")
            XCTAssertFalse(tabs.isTabBarHidden, "the tab bar did not come back on Chats after \(conversation)")
        }
    }
}
#endif
