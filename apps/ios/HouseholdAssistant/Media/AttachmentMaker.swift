// Turns what the person picked into what a message carries: a photo as a JPEG with its
// size in pixels, a video with its length and its size as it plays, any file as it is, a
// scan as one PDF, and a contact as a vCard file. Each comes with the small picture the
// composer shows of it while it waits to be sent.

import AVFoundation
import Contacts
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

@MainActor
enum AttachmentMaker {
    enum Refusal: Error {
        case tooLarge
        case unreadable
        case contactsOff

        var reason: String {
            switch self {
            case .tooLarge:
                return "That is too large to send"
            case .unreadable:
                return "That could not be read"
            case .contactsOff:
                return "Allow Steward AI to use Contacts in Settings to send that contact"
            }
        }
    }

    typealias Made = Result<StagedAttachment, Refusal>

    /// The composer's tiles are 64 points.
    private static let previewPixels: CGFloat = 192

    static func isImageProvider(_ provider: NSItemProvider) -> Bool {
        provider.canLoadObject(ofClass: UIImage.self) || provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
    }

    /// Clipboard data belongs to the item provider, including screenshots copied and
    /// deleted without ever entering Photos. No photo-library permission is needed.
    static func pasted(_ providers: [NSItemProvider]) async -> [Made] {
        var made: [Made] = []
        providerLoop: for provider in providers {
            var image: UIImage?
            if provider.canLoadObject(ofClass: UIImage.self) {
                image = await withCheckedContinuation { continuation in
                    provider.loadObject(ofClass: UIImage.self) { object, _ in
                        continuation.resume(returning: object as? UIImage)
                    }
                }
            }
            if image == nil {
                for type in provider.registeredTypeIdentifiers where UTType(type)?.conforms(to: .image) == true {
                    let data: Data? = await withCheckedContinuation { continuation in
                        provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                            continuation.resume(returning: data)
                        }
                    }
                    if let data, data.count > RoomAttachment.largestBytes {
                        made.append(.failure(.tooLarge))
                        continue providerLoop
                    }
                    if let data, let decoded = UIImage(data: data) {
                        image = decoded
                        break
                    }
                }
            }
            guard let image else {
                made.append(.failure(.unreadable))
                continue
            }
            // Keep screenshot text and chart lines lossless when the PNG fits.
            if let png = image.pngData(), png.count <= RoomAttachment.largestBytes {
                made.append(.success(StagedAttachment(
                    attachment: RoomAttachment(data: png, kind: .photo, mime: "image/png",
                        width: Int(image.size.width * image.scale), height: Int(image.size.height * image.scale)),
                    preview: await MediaThumbnails.image(from: png, pixels: previewPixels)
                )))
            } else {
                made.append(await photo(image))
            }
        }
        return made
    }

    /// Photos and videos from the photo picker, in the order they were picked.
    static func picked(_ items: [PhotosPickerItem]) async -> [Made] {
        var made: [Made] = []
        for item in items {
            if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                guard let movie = try? await item.loadTransferable(type: PickedMovie.self) else {
                    made.append(.failure(.unreadable))
                    continue
                }
                made.append(await video(at: movie.file))
                try? FileManager.default.removeItem(at: movie.file)
            } else {
                guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
                    made.append(.failure(.unreadable))
                    continue
                }
                made.append(await photo(image))
            }
        }
        return made
    }

    static func photo(_ image: UIImage) async -> Made {
        guard let jpeg = image.jpegData(compressionQuality: 0.85) else {
            return .failure(.unreadable)
        }
        guard jpeg.count <= RoomAttachment.largestBytes else {
            return .failure(.tooLarge)
        }
        let attachment = RoomAttachment(
            data: jpeg,
            kind: .photo,
            mime: "image/jpeg",
            width: Int(image.size.width * image.scale),
            height: Int(image.size.height * image.scale)
        )
        return .success(StagedAttachment(
            attachment: attachment,
            preview: await MediaThumbnails.image(from: jpeg, pixels: previewPixels)
        ))
    }

    /// A video file, with its length and its size as it plays, turned the way it was filmed.
    static func video(at file: URL) async -> Made {
        guard let bytes = size(of: file) else {
            return .failure(.unreadable)
        }
        guard bytes <= RoomAttachment.largestBytes else {
            return .failure(.tooLarge)
        }
        guard let data = try? Data(contentsOf: file) else {
            return .failure(.unreadable)
        }
        let asset = AVURLAsset(url: file)
        let seconds = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        var width: Int?
        var height: Int?
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let shape = try? await track.load(.naturalSize, .preferredTransform) {
            let turned = shape.0.applying(shape.1)
            width = Int(abs(turned.width).rounded())
            height = Int(abs(turned.height).rounded())
        }
        let attachment = RoomAttachment(
            data: data,
            kind: .video,
            mime: UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "video/quicktime",
            durationMs: seconds.isFinite ? Int((seconds * 1000).rounded()) : nil,
            width: width,
            height: height
        )
        return .success(StagedAttachment(
            attachment: attachment,
            preview: await MediaThumbnails.image(for: file, isVideo: true, pixels: previewPixels)
        ))
    }

    /// Any file from Files, sent as it is under its own name.
    static func file(at url: URL) -> Made {
        let isScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isScoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        guard let bytes = size(of: url) else {
            return .failure(.unreadable)
        }
        guard bytes <= RoomAttachment.largestBytes else {
            return .failure(.tooLarge)
        }
        guard let data = try? Data(contentsOf: url) else {
            return .failure(.unreadable)
        }
        return .success(StagedAttachment(
            attachment: RoomAttachment(
                data: data,
                kind: .file,
                mime: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream",
                name: fileName(url.deletingPathExtension().lastPathComponent, extension: url.pathExtension)
            ),
            preview: nil
        ))
    }

    /// A scanned document as one PDF, a page for each page scanned.
    static func scan(_ scan: VNDocumentCameraScan) -> Made {
        guard scan.pageCount > 0 else {
            return .failure(.unreadable)
        }
        let width: CGFloat = 612
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: width, height: 792)).pdfData { context in
            for index in 0..<scan.pageCount {
                let page = scan.imageOfPage(at: index)
                let bounds = CGRect(x: 0, y: 0, width: width, height: width * page.size.height / max(page.size.width, 1))
                context.beginPage(withBounds: bounds, pageInfo: [:])
                // A JPEG of about 200 dots to the inch keeps a page sharp and the file small.
                let scale = min(1700 / max(page.size.width, page.size.height, 1), 1)
                let smaller = page.preparingThumbnail(of: CGSize(width: page.size.width * scale, height: page.size.height * scale)) ?? page
                let compressed = smaller.jpegData(compressionQuality: 0.7).flatMap(UIImage.init(data:)) ?? smaller
                compressed.draw(in: bounds)
            }
        }
        guard data.count <= RoomAttachment.largestBytes else {
            return .failure(.tooLarge)
        }
        return .success(StagedAttachment(
            attachment: RoomAttachment(
                data: data,
                kind: .file,
                mime: "application/pdf",
                name: fileName(scan.title.isEmpty ? "Scan" : scan.title, extension: "pdf")
            ),
            preview: scan.imageOfPage(at: 0).preparingThumbnail(of: CGSize(width: previewPixels, height: previewPixels))
        ))
    }

    /// A contact as a vCard file. The picker hands over a whole contact without asking,
    /// and the contacts permission is asked for only when it did not.
    static func contact(_ contact: CNContact) async -> Made {
        let keys = [CNContactVCardSerialization.descriptorForRequiredKeys()]
        var whole = contact
        if !contact.areKeysAvailable(keys) {
            let store = CNContactStore()
            guard (try? await store.requestAccess(for: .contacts)) == true else {
                return .failure(.contactsOff)
            }
            guard let fetched = try? store.unifiedContact(withIdentifier: contact.identifier, keysToFetch: keys) else {
                return .failure(.unreadable)
            }
            whole = fetched
        }
        guard let data = try? CNContactVCardSerialization.data(with: [whole]) else {
            return .failure(.unreadable)
        }
        let name = CNContactFormatter.string(from: whole, style: .fullName) ?? "Contact"
        return .success(StagedAttachment(
            attachment: RoomAttachment(data: data, kind: .file, mime: "text/vcard", name: fileName(name, extension: "vcf")),
            preview: nil
        ))
    }

    private static func size(of file: URL) -> Int? {
        try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize
    }

    /// A name the gateway keeps as one plain file name: no folder separators, and no
    /// longer than its 200 characters.
    private static func fileName(_ stem: String, extension fileExtension: String) -> String {
        var cleaned = stem
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." {
            cleaned = "File"
        }
        let suffix = fileExtension.isEmpty ? "" : "." + fileExtension
        while (cleaned + suffix).utf16.count > 200, !cleaned.isEmpty {
            cleaned.removeLast()
        }
        return cleaned + suffix
    }
}
