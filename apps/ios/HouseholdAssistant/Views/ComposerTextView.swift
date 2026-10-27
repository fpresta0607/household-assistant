import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Native text editing, including the system's screenshot suggestion and Paste menu.
/// Images go to the attachment tray; UIKit still owns text selection and text paste.
struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let maxLines: Int
    var resetGeneration: Int = 0
    let onPasteImages: ([NSItemProvider]) -> Void
    @Environment(\.readingStyle) private var readingStyle

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ImagePasteTextView {
        let view = ImagePasteTextView(frame: .zero, textContainer: nil)
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.isScrollEnabled = false
        view.accessibilityIdentifier = "composer.field"
        view.accessibilityLabel = "Message"
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: ImagePasteTextView, context: Context) {
        context.coordinator.parent = self
        view.onPasteImages = onPasteImages
        if view.font != readingStyle.selectionFont {
            view.font = readingStyle.selectionFont
            view.revealCaretAfterLayout()
        }
        view.textColor = UIColor(Palette.text)
        view.tintColor = UIColor(Palette.highlight)
        if context.coordinator.resetGeneration != resetGeneration {
            // Clear a sent draft in the existing field, including marked dictation/IME
            // text. Recreating the view drops keyboard focus and flickers its height.
            context.coordinator.isResetting = true
            view.unmarkText()
            view.text = text
            view.selectedRange = NSRange(location: (text as NSString).length, length: 0)
            view.setContentOffset(.zero, animated: false)
            context.coordinator.resetGeneration = resetGeneration
            context.coordinator.isResetting = false
            view.revealCaretAfterLayout()
        } else if view.text != text, view.markedTextRange == nil {
            // Ordinary keystrokes must not rewrite UIKit's text: that loses selection/IME.
            view.text = text
            view.revealCaretAfterLayout()
        }
        view.placeholder.font = view.font
        view.placeholder.textColor = UIColor(Palette.secondaryText)
        view.placeholder.isHidden = !text.isEmpty
        if isFocused != view.isFirstResponder {
            if isFocused {
                // A newly made field is not in its window until after this update.
                DispatchQueue.main.async { [weak view] in
                    guard context.coordinator.parent.isFocused else { return }
                    view?.becomeFirstResponder()
                }
            } else {
                view.resignFirstResponder()
            }
        }
        view.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ImagePasteTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width.isFinite else { return nil }
        let line = uiView.font?.lineHeight ?? 21
        let needed = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let ceiling = ceil(line * CGFloat(maxLines))
        // SwiftUI can ask about several widths before choosing one. Scrolling is
        // decided in layoutSubviews, using the bounds it actually assigns.
        return CGSize(width: width, height: min(max(needed, ceil(line)), ceiling))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView
        var resetGeneration: Int
        var isResetting = false
        init(_ parent: ComposerTextView) {
            self.parent = parent
            resetGeneration = parent.resetGeneration
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isResetting else { return }
            parent.text = textView.text
            (textView as? ImagePasteTextView)?.placeholder.isHidden = !textView.text.isEmpty
            textView.invalidateIntrinsicContentSize()
            (textView as? ImagePasteTextView)?.revealCaretAfterLayout()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isResetting else { return }
            (textView as? ImagePasteTextView)?.revealCaretAfterLayout()
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.isFocused = true
            (textView as? ImagePasteTextView)?.revealCaretAfterLayout()
        }
        func textViewDidEndEditing(_ textView: UITextView) { parent.isFocused = false }
    }
}

final class ImagePasteTextView: UITextView {
    var onPasteImages: (([NSItemProvider]) -> Void)?
    let placeholder = UILabel()
    private var needsCaretReveal = false
    private var lastLayoutSize = CGSize.zero

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.image.identifier, UTType.text.identifier])
        placeholder.text = "Message"
        placeholder.isUserInteractionEnabled = false
        placeholder.isAccessibilityElement = false
        addSubview(placeholder)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        placeholder.frame = CGRect(x: 0, y: 0, width: bounds.width, height: font?.lineHeight ?? 21)
        guard bounds.width > 0, bounds.height > 0 else { return }

        let resized = bounds.size != lastLayoutSize
        lastLayoutSize = bounds.size
        let needed = sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude)).height
        let shouldScroll = needed > bounds.height + 0.5
        if isScrollEnabled != shouldScroll {
            isScrollEnabled = shouldScroll
            needsCaretReveal = true
            setNeedsLayout()
            // Let UITextView finish enabling its scroll geometry before revealing
            // the caret. The next layout keeps the request even at the same size.
            if shouldScroll { return }
        }
        if !shouldScroll, contentOffset != .zero {
            setContentOffset(.zero, animated: false)
        }

        // Follow edits and cursor moves after wrapping and the capped frame settle.
        // Merely scrolling back to read the draft must not snap it to the cursor.
        guard needsCaretReveal || resized else { return }
        needsCaretReveal = false
        guard isFirstResponder, shouldScroll, !isDragging, !isDecelerating,
              let selection = selectedTextRange, selection.isEmpty else { return }
        let caret = caretRect(for: selection.end)
        guard !caret.isNull, !caret.isInfinite else { return }
        scrollRectToVisible(caret.insetBy(dx: 0, dy: -2), animated: false)
    }

    func revealCaretAfterLayout() {
        needsCaretReveal = true
        setNeedsLayout()
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), UIPasteboard.general.hasImages { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override func canPaste(_ itemProviders: [NSItemProvider]) -> Bool {
        itemProviders.contains(where: AttachmentMaker.isImageProvider) || super.canPaste(itemProviders)
    }

    override func paste(_ sender: Any?) {
        // Read the pasteboard only after an explicit paste, never on focus or polling.
        if UIPasteboard.general.hasImages {
            paste(itemProviders: UIPasteboard.general.itemProviders)
        } else {
            super.paste(sender)
        }
    }

    override func paste(itemProviders: [NSItemProvider]) {
        let images = itemProviders.filter(AttachmentMaker.isImageProvider)
        guard !images.isEmpty else {
            super.paste(itemProviders: itemProviders)
            return
        }
        onPasteImages?(images)
        // A separate text item is still pasted at the selection. Alternate text/URL
        // representations of an image are not inserted as filenames into the draft.
        let words = itemProviders.filter { !AttachmentMaker.isImageProvider($0) }
        if !words.isEmpty { super.paste(itemProviders: words) }
    }
}
