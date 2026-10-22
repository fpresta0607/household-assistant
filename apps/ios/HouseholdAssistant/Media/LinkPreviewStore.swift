// Previews of the links people send: the page's title, picture, site and icon, read by
// LinkPresentation once per address and kept on this phone, so a link scrolled past
// again shows its card at once and the page is not asked twice. A page that gave nothing
// is not asked again until the app starts again.

import CryptoKit
import LinkPresentation
import UIKit

@MainActor
final class LinkPreviewStore {
    struct Preview {
        let title: String?
        /// The site's name as people say it: "example.com", without "www.".
        let site: String
        let image: UIImage?
        let icon: UIImage?
    }

    /// What is kept on disk for a link.
    private struct Record: Codable {
        let title: String?
        let site: String
        let image: Data?
        let icon: Data?
    }

    static let shared = LinkPreviewStore()

    private var previews: [URL: Preview] = [:]
    private var reading: [URL: Task<Preview?, Never>] = [:]
    private var unreadable: Set<URL> = []
    private let directory: URL

    init(
        directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("link-previews", isDirectory: true)
    ) {
        self.directory = directory
    }

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// The first web address in `text`, if it has one.
    static func link(in text: String) -> URL? {
        guard let detector, !text.isEmpty else {
            return nil
        }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap(\.url)
            .first { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
    }

    /// The preview already in memory, for drawing a card without waiting.
    func kept(_ url: URL) -> Preview? {
        previews[url]
    }

    func preview(for url: URL) async -> Preview? {
        if let preview = previews[url] {
            return preview
        }
        guard !unreadable.contains(url) else {
            return nil
        }
        if let running = reading[url] {
            return await running.value
        }
        let task = Task { await self.read(url) }
        reading[url] = task
        let preview = await task.value
        reading[url] = nil
        if let preview {
            previews[url] = preview
        } else {
            unreadable.insert(url)
        }
        return preview
    }

    /// Keeps a preview made on this phone: the screenshot tests' and the demo's, which
    /// never reach the web.
    func keep(_ preview: Preview, for url: URL) {
        previews[url] = preview
    }

    private func read(_ url: URL) async -> Preview? {
        let file = location(for: url)
        if let data = try? Data(contentsOf: file), let record = try? JSONDecoder().decode(Record.self, from: data) {
            return Self.preview(from: record)
        }
        let provider = LPMetadataProvider()
        guard let metadata = try? await provider.startFetchingMetadata(for: url) else {
            return nil
        }
        let record = Record(
            title: metadata.title,
            site: Self.site(of: metadata.url ?? url),
            image: await Self.image(from: metadata.imageProvider, longest: 600)?.jpegData(compressionQuality: 0.8),
            icon: await Self.image(from: metadata.iconProvider, longest: 64)?.pngData()
        )
        if let data = try? JSONEncoder().encode(record) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        return Self.preview(from: record)
    }

    private func location(for url: URL) -> URL {
        let name = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".json")
    }

    private static func preview(from record: Record) -> Preview {
        Preview(
            title: record.title,
            site: record.site,
            image: record.image.flatMap(UIImage.init(data:)),
            icon: record.icon.flatMap(UIImage.init(data:))
        )
    }

    static func site(of url: URL) -> String {
        let host = url.host() ?? url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// A page's picture or icon, made no larger than it is drawn before it is kept. The
    /// provider answers on a queue of its own, so this is not the main actor's.
    nonisolated private static func image(from provider: NSItemProvider?, longest: CGFloat) async -> UIImage? {
        guard let provider, provider.canLoadObject(ofClass: UIImage.self) else {
            return nil
        }
        let image: UIImage? = await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: UIImage.self) { object, _ in
                continuation.resume(returning: object as? UIImage)
            }
        }
        guard let image else {
            return nil
        }
        let scale = min(longest / max(image.size.width, image.size.height, 1), 1)
        return await image.byPreparingThumbnail(ofSize: CGSize(width: image.size.width * scale, height: image.size.height * scale))
    }
}
