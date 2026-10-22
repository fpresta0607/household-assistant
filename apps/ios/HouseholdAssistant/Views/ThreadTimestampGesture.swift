import SwiftUI
import UIKit

struct ThreadTimestampGesture: UIGestureRecognizerRepresentable {
    /// Where the swipe began, in the window, so the list can tell which message it is on.
    let onBegin: (CGPoint) -> Void
    let onChange: (CGFloat) -> Void
    let onEnd: () -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.maximumNumberOfTouches = 1
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began:
            onBegin(recognizer.location(in: recognizer.view?.window))
            onChange(max(0, -recognizer.translation(in: recognizer.view?.window).x))
        case .changed:
            onChange(max(0, -recognizer.translation(in: recognizer.view?.window).x))
        case .ended, .cancelled, .failed:
            onEnd()
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view?.window)
            return velocity.x < 0 && abs(velocity.x) > abs(velocity.y) * 1.3
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // Decide direction before the scroll view starts. A vertical drag fails
            // immediately and remains the scroll view's own gesture.
            otherGestureRecognizer is UIPanGestureRecognizer
                && otherGestureRecognizer.view is UIScrollView
        }
    }
}
