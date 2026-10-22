#if DEBUG
import Foundation

@MainActor
final class DemoTimestampObservation {
    static let shared = DemoTimestampObservation()

    var viewport = CGRect.zero
    var frames: [String: CGRect] = [:]
    private var isHeld = false
    private var observation: Task<Void, Never>?

    func held(_ isHeld: Bool) {
        guard DemoLongMessages.isRequested,
              let control = UserDefaults.standard.string(forKey: "StewardMessageActionsControl"),
              self.isHeld != isHeld else { return }
        self.isHeld = isHeld
        observation?.cancel()
        guard isHeld else { return }
        observation = Task {
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            // These frames come from the rendered Text views, after layout, while the
            // actual recognizer still owns the finger. The UI test cannot poll mid-drag.
            let visible = frames.values.filter { !$0.isEmpty && viewport.contains($0) }
            print("thread.list timestamps held \(self.isHeld), viewport \(viewport), inside \(visible.count) of \(frames.count)")
            // A swipe shows the timestamp of the message it is on, and only that one.
            guard self.isHeld, visible.count == 1 else { return }
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName((control + ".timestamps-held") as CFString), nil, nil, true
            )
        }
    }
}
#endif
