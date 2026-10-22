// The app entry point.

import SwiftUI
import UIKit
import UserNotifications

@main
struct HouseholdAssistantApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onOpenURL { model.open($0) }
                .task {
                    model.connect()
                }
                // From the first phase on, so a locked app asks Face ID as soon as it is in
                // front, while the welcome plays.
                .onChange(of: scenePhase, initial: true) { _, phase in
                    model.cover.moved(to: phase)
                }
                .onChange(of: scenePhase) { _, phase in
                    // Only a real move counts for the connection banner: inactive is a
                    // glance at Control Center, or the app on its way between the two.
                    if phase != .inactive {
                        model.appMoved(toFront: phase == .active)
                    }
                    // Back in front: a share whose time ran out while the app slept ends
                    // now, and one still on gets a fresh position. What was shared from
                    // another app meanwhile is sent. And with notifications allowed, this
                    // phone asks Apple for its address again, so a phone that missed the
                    // step after pairing, or whose gateway lost it, is notified from the
                    // next time it is opened.
                    if phase == .active {
                        model.collectShares()
                        Task {
                            await model.permissions.refresh()
                            await model.location.endIfOver()
                            model.followLocation()
                        }
                    }
                }
        }
    }
}

/// Apple's address for this phone arrives here, and so does what the person did with a
/// notification: a tap, a reply or a reaction.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// The window the welcome and App Lock are drawn in, over the app's own.
    private var coverWindow: CoverWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        MainActor.assumeIsolated {
            ChatTiming.launched()
        }
        UNUserNotificationCenter.current().delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(sceneWillConnect(_:)), name: UIScene.willConnectNotification, object: nil)
        AudioFocus.rest()
        // Keep iOS's native bar appearance and scroll-edge treatment. A transparent
        // appearance override prevents the glass from protecting text over dark content.
        // iOS may have started the app in the background to say it moved while its person
        // shares where they are. Watching again is what hands that over.
        MainActor.assumeIsolated {
            AppModel.shared.followLocation()
            AppModel.shared.metrics.start()
            AppModel.shared.network.start()
        }
        return true
    }

    /// Puts the welcome and App Lock's window over the app's own before the app's first
    /// frame, and starts the welcome when Chats is what opens under it: not in the first
    /// run, and not in the demo, whose UI tests time Chats from launch, unless a test asks
    /// for it with `-StewardWelcome YES` to time the launch with it (LaunchSpeedTests).
    @objc private func sceneWillConnect(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene else {
            return
        }
        MainActor.assumeIsolated {
            let model = AppModel.shared
            if model.isPaired && model.settings.hasOfferedPermissions && (!Self.isDemo || Self.isWelcomeRequested) {
                model.cover.welcome()
            }
            coverWindow = CoverWindow(scene: scene, model: model)
        }
    }

    @MainActor
    private static var isDemo: Bool {
        #if DEBUG
        return DemoGateway.isRequested
        #else
        return false
        #endif
    }

    private static var isWelcomeRequested: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "StewardWelcome")
        #else
        return false
        #endif
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        MainActor.assumeIsolated {
            AppModel.shared.push.didRegister(deviceToken: deviceToken)
        }
    }

    /// A notification for the conversation already on screen is not shown again: the
    /// bubble arriving is the notice.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let conversation = Self.conversation(of: notification)
        let isOnScreen = await MainActor.run {
            AppModel.shared.tab == .chats && AppModel.shared.path.last == conversation
        }
        return isOnScreen ? [] : [.banner, .list, .sound]
    }

    /// A reply or a reaction may have woken the app in the background, and iOS keeps it
    /// running until this returns, so it returns once the answer is sent.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let content = response.notification.request.content
        guard let answer = NotificationAnswer(
            action: response.actionIdentifier,
            typed: (response as? UNTextInputNotificationResponse)?.userText,
            conversation: content.userInfo[NotificationPayload.conversationKey] as? String ?? content.threadIdentifier,
            messageId: content.userInfo[NotificationPayload.messageIdKey] as? String
        ) else {
            return
        }
        await Self.answer(answer)
    }

    @MainActor
    private static func answer(_ answer: NotificationAnswer) async {
        await AppModel.shared.answer(answer)
    }

    private static func conversation(of notification: UNNotification) -> RoomConversation? {
        let content = notification.request.content
        let named = content.userInfo[NotificationPayload.conversationKey] as? String ?? content.threadIdentifier
        return RoomConversation(rawValue: named)
    }
}
