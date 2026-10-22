#if canImport(UIKit)
// What covers the app as it moves between the background, inactive and in front, with Face
// ID answered by a script: a fresh open with App Lock on asks once and opens when it passes,
// a cancel shows Unlock and is not asked again until the app comes back from the
// background, an iPhone with no passcode opens, Face ID's own question never raises the
// cover, the cover is up whenever the app is out of sight with the lock on, and the welcome
// covers the app until a tap ends it.

import SwiftUI
import XCTest
@testable import HouseholdAssistant

@MainActor
final class AppCoverTests: XCTestCase {
    /// Face ID as the tests answer it: each check takes the next outcome, and may do what
    /// iOS does while its question is up, which leaves the app inactive.
    @MainActor
    private final class ScriptedCheck {
        var outcomes: [DeviceOwnerCheck.Outcome]
        var whileAsking: () -> Void = {}
        private(set) var asked = 0

        init(_ outcomes: [DeviceOwnerCheck.Outcome]) {
            self.outcomes = outcomes
        }

        func run() -> DeviceOwnerCheck.Outcome {
            asked += 1
            whileAsking()
            return outcomes.isEmpty ? .refused : outcomes.removeFirst()
        }
    }

    private var suiteName = ""
    private var defaults = UserDefaults.standard
    private lazy var settings = AppSettings(defaults: defaults)

    override func setUp() async throws {
        suiteName = "app-cover-tests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func cover(answering script: ScriptedCheck) -> AppCover {
        AppCover(settings: settings) { _ in
            await script.run()
        }
    }

    /// Waits, a second at most, for what a check started by the scene leaves behind.
    private func settle(until isDone: () -> Bool) async throws {
        for _ in 0..<100 {
            if isDone() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testAFreshOpenWithTheLockOnAsksOnceAndOpensWhenFaceIDPasses() async throws {
        // Arrange
        settings.isAppLockOn = true
        let script = ScriptedCheck([.passed])
        let cover = cover(answering: script)
        let isShownBeforeFront = cover.isShown

        // Act
        cover.moved(to: .inactive)
        cover.moved(to: .active)
        try await settle { !cover.lock.isLocked }

        // Assert
        XCTAssertTrue(isShownBeforeFront, "nothing of the app shows before Face ID")
        XCTAssertEqual(script.asked, 1)
        XCTAssertFalse(cover.lock.isLocked)
        XCTAssertFalse(cover.isShown)
    }

    func testACancelShowsUnlockAndAGlanceDoesNotAskAgain() async throws {
        // Arrange
        settings.isAppLockOn = true
        let script = ScriptedCheck([.refused])
        let cover = cover(answering: script)

        // Act
        cover.moved(to: .active)
        try await settle { cover.isUnlockShown }
        cover.moved(to: .inactive)
        cover.moved(to: .active)
        try await Task.sleep(for: .milliseconds(100))

        // Assert
        XCTAssertEqual(script.asked, 1, "Control Center and back is not a new open")
        XCTAssertTrue(cover.lock.isLocked)
        XCTAssertTrue(cover.isUnlockShown)
        XCTAssertTrue(cover.isShown)
    }

    func testUnlockAsksAgainAfterACancel() async throws {
        // Arrange
        settings.isAppLockOn = true
        let script = ScriptedCheck([.refused, .passed])
        let cover = cover(answering: script)
        cover.moved(to: .active)
        try await settle { cover.isUnlockShown }

        // Act
        await cover.unlock()

        // Assert
        XCTAssertEqual(script.asked, 2)
        XCTAssertFalse(cover.lock.isLocked)
        XCTAssertFalse(cover.isUnlockShown)
    }

    func testBackFromTheBackgroundAfterACancelAsksByItself() async throws {
        // Arrange
        settings.isAppLockOn = true
        let script = ScriptedCheck([.refused, .passed])
        let cover = cover(answering: script)
        cover.moved(to: .active)
        try await settle { cover.isUnlockShown }

        // Act
        cover.moved(to: .background)
        cover.moved(to: .inactive)
        cover.moved(to: .active)
        try await settle { !cover.lock.isLocked }

        // Assert
        XCTAssertEqual(script.asked, 2)
        XCTAssertFalse(cover.lock.isLocked)
    }

    func testAnIPhoneWithNoPasscodeOpensRatherThanStayingShut() async throws {
        // Arrange
        settings.isAppLockOn = true
        let cover = cover(answering: ScriptedCheck([.unavailable]))

        // Act
        cover.moved(to: .active)
        try await settle { !cover.lock.isLocked }

        // Assert
        XCTAssertFalse(cover.lock.isLocked)
        XCTAssertFalse(cover.isShown)
    }

    /// iOS's Face ID question leaves the app inactive while it is up, and the answer can
    /// come before the app is active again: the cover must not flash either way.
    func testFaceIDsOwnQuestionNeverRaisesTheCover() async {
        // Arrange
        let script = ScriptedCheck([.passed])
        let cover = cover(answering: script)
        cover.moved(to: .active)
        script.whileAsking = {
            cover.moved(to: .inactive)
        }

        // Act
        let outcome = await cover.requireFaceID()
        let isShownBeforeActive = cover.isShown
        cover.moved(to: .active)

        // Assert
        XCTAssertEqual(outcome, .passed)
        XCTAssertTrue(settings.isAppLockOn, "Require Face ID turns on once Face ID passes")
        XCTAssertFalse(isShownBeforeActive)
        XCTAssertFalse(cover.isShown)
    }

    func testRequireFaceIDStaysOffUnlessFaceIDPasses() async {
        for outcome in [DeviceOwnerCheck.Outcome.refused, .unavailable] {
            // Arrange
            settings.isAppLockOn = false
            let cover = cover(answering: ScriptedCheck([outcome]))

            // Act
            let answered = await cover.requireFaceID()

            // Assert
            XCTAssertEqual(answered, outcome)
            XCTAssertFalse(settings.isAppLockOn, "\(outcome)")
        }
    }

    func testWithTheLockOnTheCoverIsUpWheneverTheAppIsOutOfSight() {
        // Arrange
        let cover = cover(answering: ScriptedCheck([]))
        cover.moved(to: .active)
        settings.isAppLockOn = true

        // Act
        cover.moved(to: .inactive)
        let isShownInactive = cover.isShown
        let shouldPutAwayTypingInactive = cover.shouldPutAwayTyping
        cover.moved(to: .background)
        let isShownInTheBackground = cover.isShown
        let shouldPutAwayTypingInTheBackground = cover.shouldPutAwayTyping

        // Assert
        XCTAssertTrue(isShownInactive, "the app switcher's picture shows nothing")
        XCTAssertFalse(shouldPutAwayTypingInactive, "a glance at Control Center leaves the keyboard be")
        XCTAssertTrue(isShownInTheBackground)
        XCTAssertTrue(shouldPutAwayTypingInTheBackground)
    }

    func testWithTheLockOffNothingCoversTheAppOutOfSight() {
        // Arrange
        let cover = cover(answering: ScriptedCheck([]))
        cover.moved(to: .active)

        // Act
        cover.moved(to: .inactive)
        cover.moved(to: .background)

        // Assert
        XCTAssertFalse(cover.isShown)
        XCTAssertFalse(cover.shouldPutAwayTyping)
    }

    func testTheWelcomeCoversTheAppUntilATapEndsIt() {
        // Arrange
        let cover = cover(answering: ScriptedCheck([]))

        // Act
        cover.welcome()
        let isShownWhileWelcoming = cover.isShown
        cover.endWelcome()

        // Assert
        XCTAssertTrue(isShownWhileWelcoming)
        XCTAssertFalse(cover.isShown)
    }
}
#endif
