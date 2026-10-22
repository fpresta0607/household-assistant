// What the person shared from another app, waiting in the App Group for the app to send
// (ShareOutbox). Each shows in its conversation as on its way until the room takes it,
// and is sent the way the composer sends: its files made into attachments, uploaded, and
// the message signed by this phone. It goes under its hand-off's id, so sending it again
// after the app was stopped half way is the same message to the gateway.
//
// The Share Extension says when one is ready, and a running app hears it at once. One that
// is not finds it when it next comes to the front.

import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class ShareInbox {
    /// Hand-offs the room has not been given yet, oldest first.
    private(set) var waiting: [ShareHandoff] = []
    /// Called when the Share Extension says a hand-off is ready, while the app runs.
    @ObservationIgnored var onPosted: (() -> Void)?

    @ObservationIgnored private let outbox: ShareOutbox?
    /// Being sent now, so another look does not send them twice.
    @ObservationIgnored private var sending: Set<String> = []

    init(outbox: ShareOutbox?) {
        self.outbox = outbox
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else {
                    return
                }
                let inbox = Unmanaged<ShareInbox>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in
                    inbox.onPosted?()
                }
            },
            ShareFolder.posted as CFString,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(ShareFolder.posted as CFString),
            nil
        )
    }

    func waiting(in conversation: RoomConversation) -> [ShareHandoff] {
        waiting.filter { $0.conversation == conversation }
    }

    /// Reads what waits in the App Group, so it shows in its conversation at once.
    func look() {
        waiting = (outbox?.pending() ?? []).filter { !sending.contains($0.id) }
    }

    /// Sends everything waiting, oldest first, once the room knows who this phone is. Each
    /// leaves the App Group when the room has an answer for it: kept, or refused with a
    /// retry in its bubble, as a message from the composer is.
    func send(through room: RoomModel) async {
        look()
        guard let outbox else {
            return
        }
        for handoff in waiting {
            sending.insert(handoff.id)
            waiting.removeAll { $0.id == handoff.id }
            var attachments: [RoomAttachment] = []
            for item in handoff.items {
                if let attachment = await Self.attachment(item, at: outbox.file(item, of: handoff)) {
                    attachments.append(attachment)
                }
            }
            await room.send(handoff.text, in: handoff.conversation, attachments: attachments, key: handoff.id)
            outbox.remove(handoff.id)
            sending.remove(handoff.id)
        }
    }

    /// What was shared for a gateway this phone no longer pairs with goes nowhere.
    func forget() {
        outbox?.removeAll()
        waiting = []
    }

    /// A shared file as the composer would send it: a photo as a JPEG with its size, a
    /// video with its length, anything else as it is. A picture that does not open as one
    /// goes as the file it is.
    private static func attachment(_ item: ShareHandoff.Item, at file: URL) async -> RoomAttachment? {
        let made: AttachmentMaker.Made
        switch item.kind {
        case .photo:
            if let image = UIImage(contentsOfFile: file.path) {
                made = await AttachmentMaker.photo(image)
            } else {
                made = AttachmentMaker.file(at: file)
            }
        case .video:
            made = await AttachmentMaker.video(at: file)
        case .file:
            made = AttachmentMaker.file(at: file)
        }
        return try? made.get().attachment
    }
}
