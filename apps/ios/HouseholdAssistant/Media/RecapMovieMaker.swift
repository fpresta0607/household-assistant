// A month's recap as a short video: its best shots, two seconds each with a slow push in,
// written on this phone into a temporary file the person can play, save or share. It is
// drawn off the main thread, a frame at a time, and stops when its task is cancelled.

import AVFoundation
import CoreGraphics
import CoreVideo
import Photos
import UIKit

enum RecapMovieMaker {
    enum Failure: Error {
        case noPictures
        case notWritten
    }

    static let size = CGSize(width: 1080, height: 1350)
    static let framesPerSecond: Int32 = 24
    static let secondsEach = 2.0
    /// How far each shot pushes in over its two seconds.
    static let pushIn = 0.08
    /// How long the writer may keep a frame waiting, in 5 ms waits, before the video is
    /// given up: far longer than an encoder ever takes.
    static let longestWait = 2_000

    static func make(_ recap: MonthlyRecap) async throws -> URL {
        let pictures = await pictures(of: recap.best.map(\.id))
        guard !pictures.isEmpty else {
            throw Failure.noPictures
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Recap \(recap.title).mp4")
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? Failure.notWritten
        }
        writer.startSession(atSourceTime: .zero)
        let framesEach = Int(secondsEach * Double(framesPerSecond))
        var frame: Int64 = 0
        do {
            for picture in pictures {
                for step in 0..<framesEach {
                    try Task.checkCancellation()
                    var waits = 0
                    while !input.isReadyForMoreMediaData {
                        waits += 1
                        guard waits <= longestWait else {
                            throw Failure.notWritten
                        }
                        try await Task.sleep(for: .milliseconds(5))
                    }
                    let zoom = 1 + pushIn * Double(step) / Double(framesEach)
                    guard let pool = adaptor.pixelBufferPool, let buffer = draw(picture, zoom: zoom, pool: pool),
                          adaptor.append(buffer, withPresentationTime: CMTime(value: frame, timescale: framesPerSecond)) else {
                        throw Failure.notWritten
                    }
                    frame += 1
                }
            }
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? Failure.notWritten
        }
        return url
    }

    /// The shots at the video's size, in the recap's order, fetched from iCloud when only it
    /// has the full picture. One that cannot be had is left out.
    private static func pictures(of ids: [String]) async -> [CGImage] {
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var byId: [String: PHAsset] = [:]
        fetched.enumerateObjects { asset, _, _ in
            byId[asset.localIdentifier] = asset
        }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        var pictures: [CGImage] = []
        for id in ids {
            guard let asset = byId[id] else {
                continue
            }
            let picture: CGImage? = await withCheckedContinuation { continuation in
                PHImageManager.default().requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: options) { image, _ in
                    continuation.resume(returning: image?.cgImage)
                }
            }
            if let picture {
                pictures.append(picture)
            }
        }
        return pictures
    }

    /// One frame: `picture` filling the frame, pushed in by `zoom` about its middle.
    private static func draw(_ picture: CGImage, zoom: Double, pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var made: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) == kCVReturnSuccess, let buffer = made else {
            return nil
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(buffer, [])
        }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }
        context.setFillColor(UIColor.black.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        let scale = max(size.width / CGFloat(picture.width), size.height / CGFloat(picture.height)) * CGFloat(zoom)
        let drawn = CGSize(width: CGFloat(picture.width) * scale, height: CGFloat(picture.height) * scale)
        context.interpolationQuality = .medium
        context.draw(picture, in: CGRect(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2, width: drawn.width, height: drawn.height))
        return buffer
    }
}
