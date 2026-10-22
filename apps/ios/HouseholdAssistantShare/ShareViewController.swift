// The Share Extension: what another app shares, sent to the family room or to this
// phone's own thread with its assistant.
//
// It holds no link to the gateway and no key. It copies what was shared into a draft in
// the App Group as the sheet opens, and Send names the draft ready with the conversation
// and the words (ShareOutbox), tells a running app, says it is on its way and closes. The
// app sends it the way its composer does, uploaded and signed by this phone, at once if
// it is running or when it next comes to the front.
//
// Picked from the Share Sheet's top row, it opens on that conversation: iOS hands over the
// intent the app donated for it (ShareSuggestions). Otherwise it opens on the assistant's
// thread, which nobody else reads.

import Intents
import SwiftUI
import UIKit

final class ShareViewController: UIViewController {
    private var draft: ShareDraft?

    override func viewDidLoad() {
        super.viewDidLoad()
        let snapshot = WidgetSnapshot.load()
        let suggested = (extensionContext?.intent as? INSendMessageIntent)?.conversationIdentifier
            .flatMap(RoomConversation.init(rawValue:))
        let draft = ShareDraft(outbox: ShareFolder.outbox) { [weak self] isSent in
            self?.close(isSent: isSent)
        }
        self.draft = draft

        let sheet = UIHostingController(rootView: ShareSheet(
            draft: draft,
            snapshot: snapshot,
            photos: WidgetFacePhotos.load(for: snapshot),
            conversation: suggested ?? .direct
        ))
        addChild(sheet)
        sheet.view.frame = view.bounds
        sheet.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(sheet.view)
        sheet.didMove(toParent: self)

        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        Task {
            await draft.load(items)
        }
    }

    private func close(isSent: Bool) {
        if isSent {
            extensionContext?.completeRequest(returningItems: nil)
        } else {
            extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        }
    }
}

/// The sheet, following the draft as what was shared loads.
private struct ShareSheet: View {
    let draft: ShareDraft
    let snapshot: WidgetSnapshot
    let photos: [String: UIImage]
    let conversation: RoomConversation

    var body: some View {
        ShareComposeView(
            snapshot: snapshot,
            photos: photos,
            previews: draft.previews,
            conversation: conversation,
            notice: draft.notice,
            isRefused: draft.isRefused,
            isLoading: draft.isLoading,
            isSent: draft.isSent,
            onCancel: {
                draft.cancel()
            },
            onSend: { conversation, words in
                draft.send(to: conversation, words: words)
            }
        )
    }
}
