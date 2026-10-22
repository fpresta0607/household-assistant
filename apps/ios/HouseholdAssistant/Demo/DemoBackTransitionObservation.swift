#if DEBUG
// Watches the way back from a chat to Chats frame by frame, for the UI test that a white
// card no longer flashes there (CFO notes section 9, BackTransitionTests). A UI test sees
// the screen only once the app is idle again, after the transition, so the app looks at
// its own window instead: how much of it is near white on each frame while it goes back,
// against the chat before and Chats after. It then posts `<control>.back-clean` or
// `<control>.back-flash` and prints what it measured.

import UIKit

@MainActor
final class DemoBackTransitionObservation {
    static let shared = DemoBackTransitionObservation()

    /// How long it watches from the moment the chat starts to close.
    private static let watched = Duration.milliseconds(1200)
    /// How much more of the window may be near white mid-way than at either end.
    private static let allowance = 0.08

    private var watching: Task<Void, Never>?

    func pathChanged(from old: [RoomConversation], to new: [RoomConversation]) {
        guard let control = UserDefaults.standard.string(forKey: "StewardBackTransitionControl"),
              !old.isEmpty, new.isEmpty, watching == nil else {
            return
        }
        watching = Task {
            var shares: [Double] = []
            let clock = ContinuousClock()
            let end = clock.now.advanced(by: Self.watched)
            while clock.now < end {
                if let window = Self.window {
                    shares.append(Self.whiteShare(of: window))
                }
                try? await Task.sleep(for: .milliseconds(8))
            }
            let ends = max(shares.first ?? 0, shares.last ?? 0)
            let peak = shares.max() ?? 0
            let isClean = peak <= ends + Self.allowance
            print("thread.list back transition frames \(shares.count), ends \(ends), peak \(peak): \(isClean ? "clean" : "flash")")
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName((control + (isClean ? ".back-clean" : ".back-flash")) as CFString), nil, nil, true
            )
            watching = nil
        }
    }

    private static var window: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
    }

    /// The share of the window drawn near white right now, read from a small copy of it.
    private static func whiteShare(of window: UIWindow) -> Double {
        let width = 60.0
        let size = CGSize(width: width, height: (width * window.bounds.height / max(window.bounds.width, 1)).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            window.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: false)
        }
        guard let picture = image.cgImage, let data = picture.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            return 0
        }
        let bytesPerPixel = picture.bitsPerPixel / 8
        // The bytes are read through a pointer into `data`, which must outlive the reading.
        let white = withExtendedLifetime(data) {
            var count = 0
            for row in 0..<picture.height {
                for column in 0..<picture.width {
                    let pixel = bytes + row * picture.bytesPerRow + column * bytesPerPixel
                    // Opaque, so whichever byte is alpha is full, and white is every byte high.
                    if (0..<min(bytesPerPixel, 4)).allSatisfy({ pixel[$0] >= 245 }) {
                        count += 1
                    }
                }
            }
            return count
        }
        return Double(white) / Double(max(picture.width * picture.height, 1))
    }
}
#endif
