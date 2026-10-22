// What covers Steward AI: the welcome as the app opens, and App Lock. Both are drawn in a
// window of their own over the app's (CoverWindow), so a sheet, a photo opened full screen
// or the call screen is covered as well as Chats.
//
// The welcome plays as the app opens, over Chats already drawn underneath, while the app
// restores its local store and reconnects, for `Motion.welcomeLength` and no longer, and a
// tap ends it at once. App Lock keeps the cover up while the app is locked (AppLock) and
// asks Face ID the moment the app is in front after a fresh open or the background, so on
// a fresh open Face ID runs while the welcome plays and adds no wait. Cancelled or failed,
// the cover stays with an Unlock button. While Require Face ID is on, the cover is also up
// whenever the app is not in front, so the app switcher's picture of it shows nothing. Face
// ID's own question leaves the app inactive too, which is not counted, so the cover does
// not flash as it is answered.

import Observation
import SwiftUI

@MainActor
@Observable
final class AppCover {
    /// Whether the welcome is playing.
    private(set) var isWelcoming = false
    private(set) var lock: AppLock
    /// Whether Face ID or the passcode is on screen for the app.
    private(set) var isChecking = false
    /// Whether the last check was cancelled or failed, which shows Unlock.
    private(set) var hasFailed = false
    /// Whether the app is in front, which it is not until the scene says so.
    private var isInFront = false
    /// Whether the app went to the background and is not in front again yet.
    private var isInBackground = false

    @ObservationIgnored private let settings: AppSettings
    /// Asks Face ID or the passcode, with the reason given. The tests answer it themselves.
    @ObservationIgnored private let check: @Sendable (String) async -> DeviceOwnerCheck.Outcome
    /// Whether the next time the app is in front comes after a fresh open or the
    /// background, which is when a locked app asks Face ID by itself.
    @ObservationIgnored private var shouldAskInFront = true
    @ObservationIgnored private var welcomeEnd: Task<Void, Never>?

    init(
        settings: AppSettings,
        check: @escaping @Sendable (String) async -> DeviceOwnerCheck.Outcome = DeviceOwnerCheck.run(reason:)
    ) {
        self.settings = settings
        self.check = check
        lock = AppLock(isRequired: settings.isAppLockOn)
    }

    /// Whether anything covers the app.
    var isShown: Bool {
        isWelcoming || lock.isLocked || (settings.isAppLockOn && !isInFront)
    }

    var isUnlockShown: Bool {
        lock.isLocked && hasFailed
    }

    /// Whether what was being typed should be put away, so the keyboard shows neither over
    /// a locked app nor in the app switcher's picture of it. A glance at Control Center
    /// leaves it be.
    var shouldPutAwayTyping: Bool {
        lock.isLocked || (settings.isAppLockOn && isInBackground)
    }

    /// The app opened over Chats: the welcome plays, then lifts away by itself.
    func welcome() {
        isWelcoming = true
        welcomeEnd = Task { [weak self] in
            try? await Task.sleep(for: Motion.welcomeLength)
            guard !Task.isCancelled else {
                return
            }
            self?.endWelcome()
        }
    }

    /// Ends the welcome, on a tap or once it has played.
    func endWelcome() {
        welcomeEnd?.cancel()
        isWelcoming = false
    }

    func moved(to phase: ScenePhase) {
        switch phase {
        case .background:
            isInFront = false
            isInBackground = true
            shouldAskInFront = true
            lock.movedToBack(at: .now)
        case .inactive:
            if !isChecking {
                isInFront = false
            }
        case .active:
            isInFront = true
            isInBackground = false
            lock.movedToFront(at: .now, isRequired: settings.isAppLockOn, timing: settings.appLockTiming)
            if shouldAskInFront {
                shouldAskInFront = false
                hasFailed = false
                Task {
                    await unlock()
                }
            }
        @unknown default:
            break
        }
    }

    /// Asks Face ID, or the passcode, to open a locked app. An iPhone with no passcode has
    /// nothing to check against, so it opens rather than staying shut for good.
    func unlock() async {
        guard lock.isLocked, !isChecking else {
            return
        }
        isChecking = true
        hasFailed = false
        let outcome = await check("Open Steward AI")
        isChecking = false
        switch outcome {
        case .passed, .unavailable:
            lock.unlock()
        case .refused:
            hasFailed = true
        }
    }

    /// Turns Require Face ID on once Face ID or the passcode passes, so iOS asks whether
    /// Steward AI may use Face ID now, in Settings, rather than as the app next opens.
    func requireFaceID() async -> DeviceOwnerCheck.Outcome {
        isChecking = true
        let outcome = await check("Turn on App Lock")
        isChecking = false
        if outcome == .passed {
            settings.isAppLockOn = true
        }
        return outcome
    }
}
