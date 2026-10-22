// Small pictures of photos and videos, for the bubbles and the composer, and of the
// pictures on the web that cards show: decoded at the size they are drawn, away from the
// main thread, and kept in memory while there is room, so a grid of camera photos never
// decodes twelve megapixels to fill a tile.

import AVFoundation
import ImageIO
import UIKit

@MainActor
enum MediaThumbnails {
    private static let kept = NSCache<NSString, UIImage>()

    /// A file's picture no larger than `pixels` on its longer side: the photo itself, or
    /// a video's first frame.
    static func image(for file: URL, isVideo: Bool, pixels: CGFloat) async -> UIImage? {
        let key = "\(file.path)#\(Int(pixels))" as NSString
        if let image = kept.object(forKey: key) {
            return image
        }
        let image: UIImage?
        if isVideo {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: pixels, height: pixels)
            image = try? await UIImage(cgImage: generator.image(at: .zero).image)
        } else {
            image = await Task.detached(priority: .userInitiated) {
                CGImageSourceCreateWithURL(file as CFURL, nil).flatMap { downsample($0, pixels: pixels) }
            }.value
        }
        if let image {
            kept.setObject(image, forKey: key)
        }
        return image
    }

    /// A picture on the web, such as a product's on a card, no larger than `pixels` on its
    /// longer side. Fetched through the shared session, which caches the bytes as long as
    /// the server allows, and kept decoded here like a file's picture.
    static func image(at url: URL, pixels: CGFloat) async -> UIImage? {
        let key = "\(url.absoluteString)#\(Int(pixels))" as NSString
        if let image = kept.object(forKey: key) {
            return image
        }
        guard let data = try? await URLSession.shared.data(from: url).0 else {
            return nil
        }
        let picture = await image(from: data, pixels: pixels)
        if let picture {
            kept.setObject(picture, forKey: key)
        }
        return picture
    }

    /// A picture still in memory, about to be sent.
    static func image(from data: Data, pixels: CGFloat) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            CGImageSourceCreateWithData(data as CFData, nil).flatMap { downsample($0, pixels: pixels) }
        }.value
    }

    nonisolated private static func downsample(_ source: CGImageSource, pixels: CGFloat) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
    }
}
