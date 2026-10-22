// How sharp a photo is, from a small grey thumbnail of it: the variance of its Laplacian,
// which is high where edges are crisp and low where everything is smeared. A plain loop over
// a few tens of thousands of bytes, run off the main thread with the rest of a scan.

import Foundation

enum Sharpness {
    /// Below this a photo reads as blurry, on a thumbnail about 256 pixels wide. Edges a
    /// focused photo keeps, even a calm one, measure well above it; motion blur and a missed
    /// focus fall under it.
    static let blurry: Double = 60

    /// The Laplacian's variance over `pixels`, a `width` by `height` grey image, one byte a
    /// pixel, row by row. Zero for an image too small to have an inside.
    static func variance(of pixels: [UInt8], width: Int, height: Int) -> Double {
        guard width >= 3, height >= 3, pixels.count >= width * height else {
            return 0
        }
        var sum: Double = 0
        var squares: Double = 0
        var count: Double = 0
        for row in 1..<(height - 1) {
            for column in 1..<(width - 1) {
                let at = row * width + column
                let laplacian = Double(pixels[at - width]) + Double(pixels[at + width]) + Double(pixels[at - 1]) + Double(pixels[at + 1])
                    - 4 * Double(pixels[at])
                sum += laplacian
                squares += laplacian * laplacian
                count += 1
            }
        }
        let mean = sum / count
        return squares / count - mean * mean
    }
}
