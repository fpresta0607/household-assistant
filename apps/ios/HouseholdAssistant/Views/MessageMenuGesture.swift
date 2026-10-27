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
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let root = gestureRecognizer.view else { return true }
            // After a double tap, UIKit owns the handles and press-and-drag
            // selection. Do not lift the bubble out from under that interaction.
            return !Self.hasSelection(near: touch.location(in: root), in: root)
        }

        static func hasSelection(near point: CGPoint, in view: UIView) -> Bool {
            if let text = view as? UITextView, text.isFirstResponder,
               !text.isEditable, let selection = text.selectedTextRange, !selection.isEmpty,
               text.bounds.insetBy(dx: -32, dy: -32).contains(point) {
                return true
            }
            return view.subviews.contains {
                hasSelection(near: $0.convert(point, from: view), in: $0)
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // An initial hold opens the message menu. Native double taps are untouched;
            // once text is selected, its handles and selection holds take priority.
            guard otherGestureRecognizer is UILongPressGestureRecognizer else { return false }
            var view = otherGestureRecognizer.view
            while let current = view {
                if let text = current as? UITextView {
                    return !(text.isFirstResponder && (text.selectedTextRange?.isEmpty == false))
                }
                if current === gestureRecognizer.view { return false }
                view = current.superview
            }
            return false
        }
    }
}
