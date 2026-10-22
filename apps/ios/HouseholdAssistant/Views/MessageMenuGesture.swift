import SwiftUI
import UIKit

struct MessageMenuGesture: UIGestureRecognizerRepresentable {
    /// Called with where the finger is, on screen, once the press has held.
    let onPress: (CGPoint) -> Void

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = 0.35
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        if recognizer.state == .began {
            onPress(context.converter.location(in: .global))
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // Markdown's UITextView keeps selection enabled for links. Its selection
            // hold waits for the bubble menu, while ordinary link and card taps proceed.
            guard otherGestureRecognizer is UILongPressGestureRecognizer else { return false }
            var view = otherGestureRecognizer.view
            while let current = view {
                if current is UITextView { return true }
                if current === gestureRecognizer.view { return false }
                view = current.superview
            }
            return false
        }
    }
}
