// What the person is sharing while the sheet is open: each photo, video and file copied
// into a draft in the App Group as it loads, under a plain name of its own, with a small
// picture for the sheet; each link and piece of text kept for the words; and why any of
// it cannot go. Send names the draft ready for the app (ShareOutbox), Cancel throws it
// away.

import Foundation
import Observation
import UIKit
import UniformTypeIdentifiers

@MainActor
@Observable
final class ShareDraft {
    private(set) var previews: [ShareSheetItem] = []
    private(set) var notice: String?
    private(set) var isRefused = false
    private(set) var isLoading = true
    private(set) var isSent = false

    @ObservationIgnored private let outbox: ShareOutbox?
    /// Closes the extension: true once the hand-off is posted, false when cancelled.
    @ObservationIgnored private let finish: (Bool) -> Void
    @ObservationIgnored private let id = UUID().uuidString.lowercased()
    @ObservationIgnored private var items: [ShareHandoff.Item] = []
    @ObservationIgnored private var taken: Set<String> = [ShareOutbox.manifest]
    @ObservationIgnored private var sizes: [Int] = []
    @ObservationIgnored private var shared: [String] = []
    @ObservationIgnored private var links: [URL] = []

    /// Long enough to read "On its way", short enough not to wait on.
    private static let confirmation = Duration.milliseconds(1400)
    /// The sheet's tiles are 84 points.
    private static let previewPixels: CGFloat = 252

    /// A file iOS handed over, copied into the draft, or why it was not.
    private enum Copied {
        case file(URL, name: String, bytes: Int)
        case tooLarge
        case unreadable
    }

    init(outbox: ShareOutbox?, finish: @escaping (Bool) -> Void) {
        self.outbox = outbox
        self.finish = finish
    }

    /// Reads everything the other app shared, in its order.
    func load(_ extensionItems: [NSExtensionItem]) async {
        defer {
            isLoading = false
        }
        guard let outbox, let folder = try? outbox.draft(id) else {
            refuse("Steward AI cannot reach its own folder on this iPhone. Open the app once, then share this again.")
            return
        }
        let providers = extensionItems.flatMap { $0.attachments ?? [] }
        let fileCount = providers.filter { !isLink($0) && !isText($0) }.count
        if let tooMany = RoomAttachment.refusal(sizes: Array(repeating: 0, count: fileCount)) {
            refuse(tooMany)
            return
        }
        for item in extensionItems {
            if let words = item.attributedContentText?.string {
                shared.append(words)
            }
        }
        for provider in providers {
            await load(provider, into: folder)
        }
        if let together = RoomAttachment.refusal(sizes: sizes) {
            refuse(together)
        }
    }

    func send(to conversation: RoomConversation, words: String) {
        guard let outbox, !isSent, !isRefused else {
            return
        }
        let handoff = ShareHandoff(
            id: id,
            conversation: conversation,
            text: ShareHandoff.text(words: words, shared: shared, links: links),
            items: items,
            at: Date()
        )
        do {
            try outbox.post(handoff)
        } catch {
            notice = "That could not be handed to Steward AI. Try sharing it again."
            return
        }
        ShareFolder.announce()
        isSent = true
        Task {
            try? await Task.sleep(for: Self.confirmation)
            finish(true)
        }
    }

    func cancel() {
        outbox?.discard(id)
        finish(false)
    }

    // MARK: - Reading what was shared

    private func load(_ provider: NSItemProvider, into folder: URL) async {
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            await keep(await copy(provider, as: .movie, into: folder), kind: .video, suggestedName: provider.suggestedName)
        } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            var copied = await copy(provider, as: .image, into: folder)
            if case .unreadable = copied {
                copied = await drawnImage(provider, into: folder)
            }
            await keep(copied, kind: .photo, suggestedName: provider.suggestedName)
        } else if isLink(provider) {
            if let url = await link(from: provider) {
                links.append(url)
                previews.append(ShareSheetItem(kind: .link, title: Self.address(of: url)))
            }
        } else if isText(provider) {
            if let text = await text(from: provider), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                shared.append(text)
                previews.append(ShareSheetItem(kind: .text, title: text))
            }
        } else {
            let type = provider.registeredContentTypes.first { $0.conforms(to: .data) } ?? .data
            await keep(await copy(provider, as: type, into: folder), kind: .file, suggestedName: provider.suggestedName)
        }
    }

    /// A web page's address. A file's address is the file, which is copied instead.
    private func isLink(_ provider: NSItemProvider) -> Bool {
        provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
            && !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
    }

    /// Words from Notes or a page, rather than a text file, which has a name of its own.
    private func isText(_ provider: NSItemProvider) -> Bool {
        provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) && provider.suggestedName == nil
    }

    /// Copies the file iOS hands over before it is taken away again, unless it is larger
    /// than one message carries.
    private func copy(_ provider: NSItemProvider, as type: UTType, into folder: URL) async -> Copied {
        await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, _ in
                guard let url, let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                    continuation.resume(returning: .unreadable)
                    return
                }
                guard bytes <= RoomAttachment.largestBytes else {
                    continuation.resume(returning: .tooLarge)
                    return
                }
                // Hidden until it has its own name, so a draft never posts it by accident.
                let incoming = folder.appendingPathComponent(".incoming-" + UUID().uuidString)
                do {
                    try FileManager.default.copyItem(at: url, to: incoming)
                    continuation.resume(returning: .file(incoming, name: url.lastPathComponent, bytes: bytes))
                } catch {
                    continuation.resume(returning: .unreadable)
                }
            }
        }
    }

    /// A picture another app shares only as an image in memory, such as a fresh
    /// screenshot, written out as a JPEG.
    private func drawnImage(_ provider: NSItemProvider, into folder: URL) async -> Copied {
        guard let image = await image(from: provider), let jpeg = image.jpegData(compressionQuality: 0.9) else {
            return .unreadable
        }
        guard jpeg.count <= RoomAttachment.largestBytes else {
            return .tooLarge
        }
        let incoming = folder.appendingPathComponent(".incoming-" + UUID().uuidString)
        guard (try? jpeg.write(to: incoming)) != nil else {
            return .unreadable
        }
        return .file(incoming, name: "Photo.jpg", bytes: jpeg.count)
    }

    private func link(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }

    private func text(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: String.self) { text, _ in
                continuation.resume(returning: text)
            }
        }
    }

    private func image(from provider: NSItemProvider) async -> UIImage? {
        guard provider.canLoadObject(ofClass: UIImage.self) else {
            return nil
        }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: UIImage.self) { image, _ in
                continuation.resume(returning: image as? UIImage)
            }
        }
    }

    /// Gives a copied file its own plain name in the draft and its picture in the sheet,
    /// or says why it was left out.
    private func keep(_ copied: Copied, kind: ShareHandoff.Item.Kind, suggestedName: String?) async {
        switch copied {
        case .tooLarge:
            notice = "Something shared is too large to send, so it was left out."
        case .unreadable:
            notice = "Something shared could not be read, so it was left out."
        case .file(let incoming, let original, let bytes):
            let fileExtension = (original as NSString).pathExtension
            let wanted = suggestedName.map { name in
                (name as NSString).pathExtension.isEmpty && !fileExtension.isEmpty ? name + "." + fileExtension : name
            } ?? original
            let name = PlainFileName.unique(wanted, taken: taken)
            let file = incoming.deletingLastPathComponent().appendingPathComponent(name)
            guard (try? FileManager.default.moveItem(at: incoming, to: file)) != nil else {
                try? FileManager.default.removeItem(at: incoming)
                notice = "Something shared could not be read, so it was left out."
                return
            }
            taken.insert(name)
            items.append(ShareHandoff.Item(kind: kind, file: name))
            sizes.append(bytes)
            switch kind {
            case .photo, .video:
                let picture = await MediaThumbnails.image(for: file, isVideo: kind == .video, pixels: Self.previewPixels)
                previews.append(ShareSheetItem(kind: kind == .photo ? .photo : .video, title: name, thumbnail: picture))
            case .file:
                previews.append(ShareSheetItem(kind: .file, title: name))
            }
        }
    }

    private func refuse(_ reason: String) {
        notice = reason
        isRefused = true
    }

    /// "example.com/weeknight-pesto-pasta": the address as a person reads it.
    private static func address(of url: URL) -> String {
        guard let host = url.host else {
            return url.absoluteString
        }
        let site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return url.path.count > 1 ? site + url.path : site
    }
}
