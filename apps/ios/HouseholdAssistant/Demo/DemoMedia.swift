#if DEBUG
// The demo household's attachments, drawn and synthesised on the phone so the demo
// carries no picture, recording or document of anyone: a plate of pasta, a voice note
// that is a soft hum shaped like speech, a one-page form, a few painted landscapes, a
// short clip of a ball crossing a playing field, and the picture a recipe page shows.

import AVFoundation
import Foundation
import UIKit

enum DemoMedia {
    /// The voice note's bars, as the recorder would have kept them.
    static let waveform: [Double] = [
        0.15, 0.35, 0.6, 0.85, 0.7, 0.4, 0.25, 0.5, 0.9, 1.0, 0.75, 0.45, 0.2, 0.3, 0.55, 0.8,
        0.65, 0.35, 0.15, 0.4, 0.7, 0.95, 0.6, 0.3, 0.2, 0.45, 0.75, 0.5, 0.25, 0.1,
    ]

    static func photo() -> Data {
        let size = CGSize(width: 900, height: 675)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let colors = [UIColor(red: 0.98, green: 0.84, blue: 0.55, alpha: 1), UIColor(red: 0.85, green: 0.45, blue: 0.25, alpha: 1)]
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors.map(\.cgColor) as CFArray,
                locations: [0, 1]
            )
            if let gradient {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
            let center = CGPoint(x: size.width / 2, y: size.height / 2 + 10)
            UIColor(white: 0, alpha: 0.12).setFill()
            UIBezierPath(ovalIn: CGRect(x: center.x - 262, y: center.y - 248, width: 530, height: 530)).fill()
            UIColor.white.setFill()
            UIBezierPath(ovalIn: CGRect(x: center.x - 270, y: center.y - 270, width: 540, height: 540)).fill()
            UIColor(white: 0.93, alpha: 1).setFill()
            UIBezierPath(ovalIn: CGRect(x: center.x - 200, y: center.y - 200, width: 400, height: 400)).fill()
            // Pasta: golden loops around the middle of the plate.
            UIColor(red: 0.96, green: 0.8, blue: 0.4, alpha: 1).setStroke()
            for index in 0..<26 {
                let angle = Double(index) * 0.73
                let radius = 40 + Double(index % 7) * 18
                let loop = UIBezierPath(
                    arcCenter: CGPoint(x: center.x + CGFloat(cos(angle) * 30), y: center.y + CGFloat(sin(angle) * 30)),
                    radius: CGFloat(radius),
                    startAngle: CGFloat(angle),
                    endAngle: CGFloat(angle + 2.4),
                    clockwise: true
                )
                loop.lineWidth = 9
                loop.lineCapStyle = .round
                loop.stroke()
            }
            UIColor(red: 0.78, green: 0.16, blue: 0.12, alpha: 0.9).setFill()
            UIBezierPath(ovalIn: CGRect(x: center.x - 70, y: center.y - 60, width: 140, height: 120)).fill()
            UIColor(red: 0.2, green: 0.55, blue: 0.25, alpha: 1).setFill()
            for (dx, dy, turn) in [(-20.0, -30.0, 0.5), (25.0, -10.0, -0.4), (-5.0, 25.0, 1.2)] {
                let leaf = UIBezierPath(ovalIn: CGRect(x: -22, y: -11, width: 44, height: 22))
                leaf.apply(CGAffineTransform(rotationAngle: CGFloat(turn)))
                leaf.apply(CGAffineTransform(translationX: center.x + CGFloat(dx), y: center.y + CGFloat(dy)))
                leaf.fill()
            }
        }
        return image.pngData() ?? Data()
    }

    /// 16 kHz mono 16-bit PCM in a WAV file: a hum whose loudness follows `waveform`.
    static func voiceNote(seconds: Int) -> Data {
        let rate = 16_000
        let count = rate * seconds
        var samples = Data(capacity: count * 2)
        for index in 0..<count {
            let time = Double(index) / Double(rate)
            let bar = waveform[min(Int(time / Double(seconds) * Double(waveform.count)), waveform.count - 1)]
            let syllable = 0.5 + 0.5 * sin(2 * .pi * 4 * time)
            let tone = sin(2 * .pi * 180 * time) + 0.4 * sin(2 * .pi * 360 * time)
            let value = Int16(max(min(tone * bar * syllable * 9_000, 32_000), -32_000))
            withUnsafeBytes(of: value.littleEndian) { samples.append(contentsOf: $0) }
        }
        var file = Data()
        func append<Value: FixedWidthInteger>(_ value: Value) {
            withUnsafeBytes(of: value.littleEndian) { file.append(contentsOf: $0) }
        }
        file.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + samples.count))
        file.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(rate))
        append(UInt32(rate * 2))
        append(UInt16(2))
        append(UInt16(16))
        file.append(contentsOf: Array("data".utf8))
        append(UInt32(samples.count))
        file.append(samples)
        return file
    }

    static func permissionSlip() -> Data {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        return UIGraphicsPDFRenderer(bounds: page).pdfData { context in
            context.beginPage()
            let title: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 24)]
            let body: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 14)]
            ("Field trip permission slip" as NSString).draw(at: CGPoint(x: 60, y: 70), withAttributes: title)
            let lines = [
                "Trip: Science museum",
                "Date: Friday, 9:00 to 15:00",
                "Bring: lunch and a water bottle",
                "",
                "Parent or guardian signature: ______________________",
            ]
            for (index, line) in lines.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 60, y: 130 + CGFloat(index) * 28), withAttributes: body)
            }
        }
    }

    enum Scene: CaseIterable {
        case beach, sunset, bloom, hills
    }

    /// A painted landscape as a JPEG, `width` by `height` pixels.
    static func scene(_ scene: Scene, width: Int, height: Int) -> Data {
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            func gradient(_ top: UIColor, _ bottom: UIColor, from: CGFloat, to: CGFloat) {
                let colors = [top.cgColor, bottom.cgColor] as CFArray
                if let shading = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                    cg.saveGState()
                    cg.clip(to: CGRect(x: 0, y: from, width: size.width, height: to - from))
                    cg.drawLinearGradient(shading, start: CGPoint(x: 0, y: from), end: CGPoint(x: 0, y: to), options: [])
                    cg.restoreGState()
                }
            }
            func hill(_ color: UIColor, crest: CGFloat, peakAt: CGFloat, rise: CGFloat) {
                let path = UIBezierPath()
                path.move(to: CGPoint(x: 0, y: size.height))
                path.addLine(to: CGPoint(x: 0, y: crest))
                path.addQuadCurve(to: CGPoint(x: size.width, y: crest + rise * 0.4), controlPoint: CGPoint(x: size.width * peakAt, y: crest - rise))
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.close()
                color.setFill()
                path.fill()
            }
            switch scene {
            case .beach:
                gradient(UIColor(red: 0.55, green: 0.8, blue: 0.97, alpha: 1), UIColor(red: 0.85, green: 0.94, blue: 1, alpha: 1), from: 0, to: size.height * 0.55)
                gradient(UIColor(red: 0.13, green: 0.55, blue: 0.75, alpha: 1), UIColor(red: 0.35, green: 0.78, blue: 0.82, alpha: 1), from: size.height * 0.55, to: size.height * 0.72)
                gradient(UIColor(red: 0.96, green: 0.87, blue: 0.66, alpha: 1), UIColor(red: 0.9, green: 0.78, blue: 0.55, alpha: 1), from: size.height * 0.72, to: size.height)
                UIColor(red: 1, green: 0.95, blue: 0.7, alpha: 1).setFill()
                UIBezierPath(ovalIn: CGRect(x: size.width * 0.72, y: size.height * 0.12, width: size.width * 0.12, height: size.width * 0.12)).fill()
            case .sunset:
                gradient(UIColor(red: 0.42, green: 0.27, blue: 0.62, alpha: 1), UIColor(red: 0.98, green: 0.55, blue: 0.3, alpha: 1), from: 0, to: size.height * 0.7)
                UIColor(red: 1, green: 0.82, blue: 0.45, alpha: 1).setFill()
                UIBezierPath(ovalIn: CGRect(x: size.width * 0.38, y: size.height * 0.48, width: size.width * 0.24, height: size.width * 0.24)).fill()
                hill(UIColor(red: 0.2, green: 0.13, blue: 0.3, alpha: 1), crest: size.height * 0.68, peakAt: 0.3, rise: size.height * 0.12)
            case .bloom:
                gradient(UIColor(red: 0.99, green: 0.86, blue: 0.9, alpha: 1), UIColor(red: 0.95, green: 0.7, blue: 0.8, alpha: 1), from: 0, to: size.height)
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let petal = min(size.width, size.height) * 0.22
                UIColor(red: 0.93, green: 0.36, blue: 0.55, alpha: 1).setFill()
                for index in 0..<6 {
                    let angle = Double(index) / 6 * 2 * .pi
                    let middle = CGPoint(x: center.x + CGFloat(cos(angle)) * petal * 0.8, y: center.y + CGFloat(sin(angle)) * petal * 0.8)
                    UIBezierPath(ovalIn: CGRect(x: middle.x - petal / 2, y: middle.y - petal / 2, width: petal, height: petal)).fill()
                }
                UIColor(red: 1, green: 0.84, blue: 0.3, alpha: 1).setFill()
                UIBezierPath(ovalIn: CGRect(x: center.x - petal * 0.4, y: center.y - petal * 0.4, width: petal * 0.8, height: petal * 0.8)).fill()
            case .hills:
                gradient(UIColor(red: 0.6, green: 0.82, blue: 0.98, alpha: 1), UIColor(red: 0.9, green: 0.96, blue: 1, alpha: 1), from: 0, to: size.height)
                hill(UIColor(red: 0.55, green: 0.76, blue: 0.45, alpha: 1), crest: size.height * 0.5, peakAt: 0.7, rise: size.height * 0.2)
                hill(UIColor(red: 0.38, green: 0.64, blue: 0.33, alpha: 1), crest: size.height * 0.68, peakAt: 0.25, rise: size.height * 0.16)
            }
        }
        return image.jpegData(compressionQuality: 0.8) ?? Data()
    }

    /// The picture on the recipe page Rosa links to: a bowl of green pasta.
    static func pestoPicture() -> UIImage {
        let size = CGSize(width: 600, height: 315)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIColor(red: 0.89, green: 0.76, blue: 0.45, alpha: 1).setFill()
            UIBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
            UIColor.white.setFill()
            UIBezierPath(ovalIn: CGRect(x: 170, y: 20, width: 260, height: 260)).fill()
            UIColor(red: 0.5, green: 0.68, blue: 0.31, alpha: 1).setStroke()
            for index in 0..<18 {
                let angle = CGFloat(index) * 0.9
                let loop = UIBezierPath(
                    arcCenter: CGPoint(x: 300 + cos(angle) * 20, y: 150 + sin(angle) * 20),
                    radius: 30 + CGFloat(index % 5) * 14,
                    startAngle: angle,
                    endAngle: angle + 2.2,
                    clockwise: true
                )
                loop.lineWidth = 8
                loop.lineCapStyle = .round
                loop.stroke()
            }
            UIColor(red: 0.95, green: 0.85, blue: 0.62, alpha: 1).setFill()
            for (x, y) in [(270.0, 120.0), (320.0, 170.0), (290.0, 185.0)] {
                UIBezierPath(ovalIn: CGRect(x: x, y: y, width: 14, height: 10)).fill()
            }
        }
    }

    /// Two seconds of a ball rolling across a playing field, as H.264 in an MP4.
    static func video() -> Data {
        let width = 640
        let height = 360
        let frames = 48
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("demo-clip-\(UUID().uuidString).mp4")
        defer {
            try? FileManager.default.removeItem(at: file)
        }
        guard let writer = try? AVAssetWriter(outputURL: file, fileType: .mp4) else {
            return Data()
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else {
            return Data()
        }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<frames {
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.005)
            }
            var buffer: CVPixelBuffer?
            if let pool = adaptor.pixelBufferPool {
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            }
            guard let buffer else {
                break
            }
            drawField(progress: Double(index) / Double(frames - 1), into: buffer, width: width, height: height)
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 24))
        }
        input.markAsFinished()
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting {
            finished.signal()
        }
        finished.wait()
        return (try? Data(contentsOf: file)) ?? Data()
    }

    /// One frame: striped grass, the pitch's white lines, and the ball `progress` of the way across.
    private static func drawField(progress: Double, into buffer: CVPixelBuffer, width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(buffer, [])
        }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            return
        }
        let size = CGSize(width: width, height: height)
        for stripe in 0..<8 {
            let shade = stripe % 2 == 0 ? 0.62 : 0.56
            context.setFillColor(UIColor(red: 0.3, green: shade, blue: 0.28, alpha: 1).cgColor)
            context.fill(CGRect(x: CGFloat(stripe) * size.width / 8, y: 0, width: size.width / 8, height: size.height))
        }
        context.setStrokeColor(UIColor(white: 1, alpha: 0.85).cgColor)
        context.setLineWidth(4)
        context.stroke(CGRect(x: 30, y: 30, width: size.width - 60, height: size.height - 60))
        context.strokeEllipse(in: CGRect(x: size.width / 2 - 50, y: size.height / 2 - 50, width: 100, height: 100))
        context.move(to: CGPoint(x: size.width / 2, y: 30))
        context.addLine(to: CGPoint(x: size.width / 2, y: size.height - 30))
        context.strokePath()
        let x = 80 + (size.width - 160) * CGFloat(progress)
        let y = size.height * 0.4 + CGFloat(sin(progress * .pi)) * 60
        context.setFillColor(UIColor(white: 0, alpha: 0.25).cgColor)
        context.fillEllipse(in: CGRect(x: x - 14, y: y - 20, width: 30, height: 12))
        context.setFillColor(UIColor.white.cgColor)
        context.fillEllipse(in: CGRect(x: x - 14, y: y - 14, width: 28, height: 28))
    }
}
#endif
