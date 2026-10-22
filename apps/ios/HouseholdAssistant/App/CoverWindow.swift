// The window the welcome and App Lock are drawn in (AppCoverView), above every other
// window of the app, so a sheet, a full screen cover or an alert is covered as well as
// Chats. It is made as the scene connects, before the app draws its first frame, so the
// welcome and a locked app show from the very first frame. It never becomes the key
// window, so the keyboard and Apple's own sheets stay with the app's window, and once the
// app locks, or goes to the background with App Lock on, whatever was being typed is put
// away so the keyboard does not stay up over the cover. It stops taking touches the moment
// the cover starts to go, and hides once the cover has faded out.

import Observation
import SwiftUI
import UIKit

final class CoverWindow: UIWindow {
    private let cover: AppCover
    private var hiding: Task<Void, Never>?

    init(scene: UIWindowScene, model: AppModel) {
        cover = model.cover
        super.init(windowScene: scene)
        windowLevel = .alert + 1
        backgroundColor = .clear
        let host = UIHostingController(rootView: AppCoverView(cover: model.cover).phonePreferences(model.settings))
        host.view.backgroundColor = .clear
        rootViewController = host
        follow()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override var canBecomeKey: Bool {
        false
    }

    /// Keeps the window in step with the cover, each time it goes up or down.
    private func follow() {
        let (isShown, shouldPutAwayTyping) = withObservationTracking {
            (cover.isShown, cover.shouldPutAwayTyping)
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.follow()
            }
        }
        hiding?.cancel()
        isUserInteractionEnabled = isShown
        if shouldPutAwayTyping {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        guard !isShown else {
            isHidden = false
            return
        }
        guard !isHidden else {
            return
        }
        hiding = Task { [weak self] in
            try? await Task.sleep(for: Motion.coverLeaveLength)
            guard !Task.isCancelled else {
                return
            }
            self?.isHidden = true
        }
    }
}
