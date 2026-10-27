import SwiftUI
import UIKit

/// Read-only text in its bubble. UIKit supplies word selection on double tap,
/// draggable selection handles, and the standard Copy / Look Up / Share menu.
struct InlineMessageText: UIViewRepresentable {
    let text: NSAttributedString
    var tint: Color = Palette.highlight
    @Environment(\.openURL) private var openURL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MessageTextView {
        let view = MessageTextView()
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: MessageTextView, context: Context) {
        context.coordinator.openURL = { openURL($0) }
        view.tintColor = UIColor(tint)
        // Unrelated row updates must leave the native selection in place.
        if !view.attributedText.isEqual(to: text) {
            view.attributedText = text
            view.invalidateIntrinsicContentSize()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: MessageTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width.isFinite else { return nil }
        // Hug short messages as SwiftUI Text did, but wrap long ones at the bubble's edge.
        let measured = text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                        options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        let fittedWidth = min(width, max(1, ceil(measured.width)))
        let fitted = uiView.sizeThatFits(CGSize(width: fittedWidth, height: .greatestFiniteMagnitude))
        return CGSize(width: fittedWidth, height: ceil(fitted.height))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var openURL: ((URL) -> Void)?

        func textView(_ textView: UITextView, shouldInteractWith URL: URL,
                      in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
            openURL?(URL)
            return false
        }
    }
}

final class MessageTextView: UITextView {
    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        isEditable = false
        isSelectable = true
        isScrollEnabled = false
        backgroundColor = .clear
        textContainerInset = .zero
        self.textContainer.lineFragmentPadding = 0
        linkTextAttributes = [:]
        textDragInteraction?.isEnabled = false
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        accessibilityIdentifier = "message.inline-text"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { selectedTextRange = nil }
        return resigned
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow == nil {
            resignFirstResponder()
            selectedTextRange = nil
        }
        super.willMove(toWindow: newWindow)
    }
}
