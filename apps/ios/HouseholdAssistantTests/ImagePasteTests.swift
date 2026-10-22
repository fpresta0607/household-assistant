#if canImport(UIKit)
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import HouseholdAssistant

@MainActor
final class ImagePasteTests: XCTestCase {
    private func screenshot() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 80, height: 120)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 120))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 10, y: 20, width: 40, height: 30))
        }
    }

    func testScreenshotProviderBecomesLosslessAttachmentWithoutPhotoLibrary() async throws {
        let png = try XCTUnwrap(screenshot().pngData())
        let provider = NSItemProvider(item: png as NSData, typeIdentifier: UTType.png.identifier)
        let made = await AttachmentMaker.pasted([provider])
        let item = try XCTUnwrap(made.first).get()
        XCTAssertEqual(item.attachment.kind, .photo)
        XCTAssertEqual(item.attachment.mime, "image/png")
        XCTAssertEqual(item.attachment.width, Int(screenshot().size.width * screenshot().scale))
        XCTAssertNotNil(UIImage(data: item.attachment.data))
    }

    func testSystemImagePasteStagesOnceAndKeepsDraftAndSelection() {
        let view = ImagePasteTextView(frame: .zero, textContainer: nil)
        view.text = "Please read this chart"
        view.selectedRange = NSRange(location: 7, length: 4)
        let provider = NSItemProvider(object: screenshot())
        var images = 0
        view.onPasteImages = { images += $0.count }
        XCTAssertTrue(view.canPaste([provider]))
        view.paste(itemProviders: [provider])
        XCTAssertEqual(images, 1)
        XCTAssertEqual(view.text, "Please read this chart")
        XCTAssertEqual(view.selectedRange, NSRange(location: 7, length: 4))
    }

    func testMenuPasteRecognizesScreenshotClipboard() {
        let saved = UIPasteboard.general.items
        defer { UIPasteboard.general.items = saved }
        UIPasteboard.general.image = screenshot()
        let view = ImagePasteTextView(frame: .zero, textContainer: nil)
        var images = 0
        view.onPasteImages = { images += $0.count }
        XCTAssertTrue(view.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil))
        view.paste(nil)
        XCTAssertEqual(images, 1)
    }

    func testUnreadableImageReportsFailure() async {
        let provider = NSItemProvider(item: Data("invalid".utf8) as NSData, typeIdentifier: UTType.png.identifier)
        let made = await AttachmentMaker.pasted([provider])
        guard case .failure(.unreadable)? = made.first else {
            return XCTFail("Invalid image data must not silently disappear")
        }
    }
}
#endif
