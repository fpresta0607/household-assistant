// Text as a QR code, black on white whatever the appearance so any camera reads it, and
// drawn square-edged at any size.

import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

struct QRCodeImage: View {
    private let image: UIImage?

    init(_ text: String) {
        image = Self.render(text)
    }

    var body: some View {
        if let image {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        }
    }

    private static func render(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let code = filter.outputImage, let drawn = CIContext().createCGImage(code, from: code.extent) else {
            return nil
        }
        return UIImage(cgImage: drawn)
    }
}
