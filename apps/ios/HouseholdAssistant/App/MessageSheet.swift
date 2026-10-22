// Apple's own message sheet, filled in before it goes up, so its To, its words and an
// event's calendar file are there the moment it shows. He can change anything in it, and
// nothing goes out until he taps send there.
//
// It runs outside the app and is presented by UIKit itself, as the contact picker is.
// UIKit's zoom grows it out of the card it was sent from: `source` is a plain view the
// card sits on.

import MessageUI
import UIKit

@MainActor
final class MessageSheet: NSObject, MFMessageComposeViewControllerDelegate {
    weak var source: UIView?
    private var onFinish: ((MessageCardState.Result) -> Void)?

    /// Whether this iPhone can send a text or an iMessage at all.
    static var canSend: Bool {
        MFMessageComposeViewController.canSendText()
    }

    /// `address` nil leaves To empty, for him to fill in. `event` goes as its calendar file
    /// where Messages takes one, and otherwise the words alone say when and where.
    /// `isZooming` false, as with Reduce Motion, puts it up the plain way. Answers whether it
    /// went up.
    func present(
        to address: String?,
        words: String,
        event: EventCard?,
        isZooming: Bool,
        onFinish: @escaping (MessageCardState.Result) -> Void
    ) -> Bool {
        guard let top = UIApplication.shared.topmostViewController else {
            return false
        }
        let composer = MFMessageComposeViewController()
        composer.messageComposeDelegate = self
        composer.recipients = address.map { [$0] } ?? []
        composer.body = words
        if let event, MFMessageComposeViewController.canSendAttachments(),
           MFMessageComposeViewController.isSupportedAttachmentUTI(EventInvite.typeIdentifier) {
            composer.addAttachmentData(
                EventInvite.file(for: event, uid: "\(UUID().uuidString)@steward.invalid", stamp: Date()),
                typeIdentifier: EventInvite.typeIdentifier,
                filename: EventInvite.fileName(for: event)
            )
        }
        if isZooming, let source {
            composer.preferredTransition = .zoom { [weak source] _ in source }
        }
        self.onFinish = onFinish
        top.present(composer, animated: true)
        return true
    }

    func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
        controller.dismiss(animated: true)
        switch result {
        case .sent:
            onFinish?(.sent)
        case .failed:
            onFinish?(.failed)
        case .cancelled:
            onFinish?(.cancelled)
        @unknown default:
            onFinish?(.cancelled)
        }
        onFinish = nil
    }
}
