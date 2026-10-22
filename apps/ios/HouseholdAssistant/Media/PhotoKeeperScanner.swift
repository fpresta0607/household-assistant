// Reading the person's photos for the photo keeper, on this phone alone and off the main
// thread: one small thumbnail at a time, already on the phone (never fetched from iCloud),
// through Vision's feature print, aesthetics score and scene labels and a sharpness count,
// down to PhotoFacts. No photo is kept, and nothing leaves the phone. Only the photos the
// person lets Steward AI read are there to read: with limited access, the ones they chose.
//
// A scan is a task of its own at utility priority, one photo after another, so the app
// stays as quick as ever while it runs, and it stops as soon as its task is cancelled.

import CoreGraphics
import Photos
import UIKit
import Vision

actor PhotoKeeperScanner {
    /// Thumbnails this size are plenty for Vision and the sharpness count, and small.
    static let thumbnailSize = CGSize(width: 256, height: 256)
    /// The most photos one scan reads: a month, or the newest of the library for a clean-out.
    static let mostPhotos = 2_000

    /// The facts of the photos taken in `interval`, newest first, at most `limit`, saying how
    /// far it has come after each. A photo whose thumbnail is not on the phone is left out.
    func facts(in interval: DateInterval, limit: Int = mostPhotos, progress: @escaping @Sendable (Int, Int) -> Void) async -> [PhotoFacts] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "mediaType == %d AND creationDate >= %@ AND creationDate < %@",
            PHAssetMediaType.image.rawValue, interval.start as NSDate, interval.end as NSDate
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = limit
        let fetched = PHAsset.fetchAssets(with: options)
        var assets: [PHAsset] = []
        fetched.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        var facts: [PhotoFacts] = []
        for (index, asset) in assets.enumerated() {
            if Task.isCancelled {
                break
            }
            if let image = await Self.thumbnail(of: asset), let read = Self.read(asset, image) {
                facts.append(read)
            }
            progress(index + 1, assets.count)
            await Task.yield()
        }
        return facts
    }

    /// A small picture of `asset` as the phone already has it, or nil when only iCloud has it.
    private static func thumbnail(of asset: PHAsset) async -> CGImage? {
        let options = PHImageRequestOptions()
        // One answer only: an opportunistic request answers twice.
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(for: asset, targetSize: thumbnailSize, contentMode: .aspectFit, options: options) { image, _ in
                continuation.resume(returning: image?.cgImage)
            }
        }
    }

    private static func read(_ asset: PHAsset, _ image: CGImage) -> PhotoFacts? {
        let featurePrint = VNGenerateImageFeaturePrintRequest()
        let aesthetics = VNCalculateImageAestheticsScoresRequest()
        let scenes = VNClassifyImageRequest()
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([featurePrint, aesthetics, scenes])
        } catch {
            return nil
        }
        let grey = Self.grey(image)
        return PhotoFacts(
            id: asset.localIdentifier,
            takenAt: asset.creationDate ?? .distantPast,
            isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot),
            isFavorite: asset.isFavorite,
            sharpness: grey.map { Sharpness.variance(of: $0.pixels, width: $0.width, height: $0.height) } ?? 0,
            score: Double(aesthetics.results?.first?.overallScore ?? 0),
            isUtility: aesthetics.results?.first?.isUtility ?? false,
            scenes: (scenes.results ?? []).filter { $0.confidence >= 0.5 }.prefix(5).map(\.identifier),
            print: featurePrint.results?.first.map(Self.floats) ?? []
        )
    }

    private static func floats(of observation: VNFeaturePrintObservation) -> [Float] {
        let count = observation.elementCount
        switch observation.elementType {
        case .float:
            return observation.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self).prefix(count)) }
        case .double:
            return observation.data.withUnsafeBytes { $0.bindMemory(to: Double.self).prefix(count).map { Float($0) } }
        default:
            return []
        }
    }

    /// `image` drawn as grey bytes, one a pixel, for the sharpness count.
    private static func grey(_ image: CGImage) -> (pixels: [UInt8], width: Int, height: Int)? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else {
            return nil
        }
        var pixels = [UInt8](repeating: 0, count: width * height)
        let isDrawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return isDrawn ? (pixels, width, height) : nil
    }
}
