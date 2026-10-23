// The microphone begins on touch-down, without waiting for a drag or a long press.
// Coordinates stay in the window while the orb grows and the keyboard closes.
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

struct VoiceNotePressGesture: UIGestureRecognizerRepresentable {
    let onBegin: () -> Void
    let onChange: (CGSize) -> Void
    let onEnd: (_ cancelled: Bool) -> Void

    func makeUIGestureRecognizer(context: Context) -> VoiceNotePressRecognizer {
        VoiceNotePressRecognizer()
    }

    func handleUIGestureRecognizerAction(_ recognizer: VoiceNotePressRecognizer, context: Context) {
        switch recognizer.state {
        case .began: onBegin()
        case .changed: onChange(recognizer.translation)
        case .ended: onEnd(false)
        case .cancelled, .failed: onEnd(true)
        default: break
        }
    }
}

final class VoiceNotePressRecognizer: UIGestureRecognizer {
    private var finger: UITouch?
    private var origin = CGPoint.zero
    private(set) var translation = CGSize.zero

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard finger == nil, let touch = touches.first else { return }
        finger = touch
        origin = touch.location(in: view?.window)
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let finger, touches.contains(finger) else { return }
        let point = finger.location(in: view?.window)
        translation = CGSize(width: point.x - origin.x, height: point.y - origin.y)
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let finger, touches.contains(finger) else { return }
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .cancelled
    }

    override func reset() {
        super.reset()
        finger = nil
        origin = .zero
        translation = .zero
    }
}
