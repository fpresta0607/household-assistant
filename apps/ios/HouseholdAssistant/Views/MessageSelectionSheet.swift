import SwiftUI
import UIKit

/// One message, with native selection handles and Copy. The original and the draft
/// remain untouched. A scrollable text view also permits selections in long messages.
struct MessageSelectionSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.readingStyle) private var style
    @State private var selection = ""

    var body: some View {
        NavigationStack {
            SelectableMessageText(text: text, font: style.selectionFont) { selection = $0 }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Copy Selection") {
                            UIPasteboard.general.string = selection
                            dismiss()
                        }
                        .disabled(selection.isEmpty)
                        .accessibilityIdentifier("message.copy-selection")
                    }
                }
        }
    }
}

struct SelectableMessageText: UIViewRepresentable {
    let text: String
    let font: UIFont
    let onSelection: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelection: onSelection) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 20, left: 16, bottom: 20, right: 16)
        view.accessibilityIdentifier = "message.selectable-text"
        view.text = text
        // Start with one word, never the whole message. The native handles can extend
        // it across paragraphs; UTF-16 ranges keep emoji and non-Latin text intact.
        if let word = text.range(of: #"\S+"#, options: .regularExpression) {
            view.selectedRange = NSRange(word, in: text)
        }
        view.delegate = context.coordinator
        DispatchQueue.main.async {
            view.becomeFirstResponder()
            context.coordinator.textViewDidChangeSelection(view)
        }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.onSelection = onSelection
        view.font = font
        view.textColor = UIColor(Palette.text)
        view.tintColor = UIColor(Palette.highlight)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var onSelection: (String) -> Void
        init(onSelection: @escaping (String) -> Void) { self.onSelection = onSelection }

        func textViewDidChangeSelection(_ textView: UITextView) {
            let range = textView.selectedRange
            let text = textView.text ?? ""
            guard let selected = Range(range, in: text) else {
                onSelection("")
                return
            }
            onSelection(String(text[selected]))
        }
    }
}

