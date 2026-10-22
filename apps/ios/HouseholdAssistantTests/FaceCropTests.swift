// The circle drawn is the circle kept: which square of a photo the face crop keeps, at
// rest, zoomed and pushed to each edge, for a wide photo and a tall one, and that no pan
// leaves a gap inside the circle.

import XCTest
@testable import HouseholdAssistant

final class FaceCropTests: XCTestCase {
    /// The 300 point circle, where an iPhone's screen puts it.
    private let circle = CGRect(x: 51, y: 276, width: 300, height: 300)
    private let wide = CGSize(width: 1_200, height: 800)
    private let tall = CGSize(width: 800, height: 1_200)
    private let square = CGSize(width: 1_000, height: 1_000)

    private func crop(_ imageSize: CGSize, scale: CGFloat = 1, offset: CGSize = .zero) -> FaceCrop {
        FaceCrop(imageSize: imageSize, circle: circle, scale: scale, offset: offset)
    }

    private func assertSame(
        _ rect: CGRect,
        _ expected: CGRect,
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let pairs = [
            (rect.minX, expected.minX, "x"),
            (rect.minY, expected.minY, "y"),
            (rect.width, expected.width, "width"),
            (rect.height, expected.height, "height"),
        ]
        for (value, wanted, name) in pairs {
            XCTAssertEqual(value, wanted, accuracy: 0.001, "\(what): \(name)", file: file, line: line)
        }
    }

    func testAtRestThePhotoJustFillsTheCircleWithItsShortSide() {
        let cases: [(what: String, image: CGSize, drawn: CGRect)] = [
            ("wide", wide, CGRect(x: -24, y: 276, width: 450, height: 300)),
            ("tall", tall, CGRect(x: 51, y: 201, width: 300, height: 450)),
            ("square", square, circle),
        ]
        for (what, image, drawn) in cases {
            assertSame(crop(image).photoFrame, drawn, what)
        }
    }

    func testAtRestTheCircleKeepsTheMiddleSquare() {
        let cases: [(what: String, image: CGSize, kept: CGRect)] = [
            ("wide", wide, CGRect(x: 200, y: 0, width: 800, height: 800)),
            ("tall", tall, CGRect(x: 0, y: 200, width: 800, height: 800)),
            ("square", square, CGRect(x: 0, y: 0, width: 1_000, height: 1_000)),
        ]
        for (what, image, kept) in cases {
            assertSame(crop(image).kept, kept, what)
        }
    }

    func testZoomingInKeepsLessAroundTheSameMiddle() {
        let cases: [(scale: CGFloat, kept: CGRect)] = [
            (2, CGRect(x: 400, y: 200, width: 400, height: 400)),
            (4, CGRect(x: 500, y: 300, width: 200, height: 200)),
        ]
        for (scale, kept) in cases {
            assertSame(crop(wide, scale: scale).kept, kept, "zoomed \(scale) times")
        }
    }

    /// Twice zoomed, a wide photo is drawn 900 by 600 points and a tall one 600 by 900,
    /// so each can move half of what it has over the circle's 300 either way.
    func testPushedToAnEdgeTheCircleKeepsThatEdge() {
        let cases: [(what: String, image: CGSize, offset: CGSize, kept: CGRect)] = [
            ("wide, left edge", wide, CGSize(width: 300, height: 0), CGRect(x: 0, y: 200, width: 400, height: 400)),
            ("wide, right edge", wide, CGSize(width: -300, height: 0), CGRect(x: 800, y: 200, width: 400, height: 400)),
            ("wide, top edge", wide, CGSize(width: 0, height: 150), CGRect(x: 400, y: 0, width: 400, height: 400)),
            ("wide, bottom edge", wide, CGSize(width: 0, height: -150), CGRect(x: 400, y: 400, width: 400, height: 400)),
            ("tall, left edge", tall, CGSize(width: 150, height: 0), CGRect(x: 0, y: 400, width: 400, height: 400)),
            ("tall, right edge", tall, CGSize(width: -150, height: 0), CGRect(x: 400, y: 400, width: 400, height: 400)),
            ("tall, top edge", tall, CGSize(width: 0, height: 300), CGRect(x: 200, y: 0, width: 400, height: 400)),
            ("tall, bottom edge", tall, CGSize(width: 0, height: -300), CGRect(x: 200, y: 800, width: 400, height: 400)),
        ]
        for (what, image, offset, kept) in cases {
            let pushed = crop(image, scale: 2, offset: offset)
            assertSame(pushed.kept, kept, what)
            // Already on the edge, so settling leaves it there.
            assertSame(pushed.settled.kept, kept, "\(what), settled")
        }
    }

    func testAPanPastAnEdgeSettlesBackOntoIt() {
        let cases: [(what: String, image: CGSize, scale: CGFloat, offset: CGSize, settled: CGSize)] = [
            ("wide, far right and up", wide, 2, CGSize(width: 1_000, height: -1_000), CGSize(width: 300, height: -150)),
            ("tall, far left and down", tall, 2, CGSize(width: -1_000, height: 1_000), CGSize(width: -150, height: 300)),
            // At rest a wide photo moves only sideways, and a tall one only up and down.
            ("wide at rest", wide, 1, CGSize(width: 50, height: 80), CGSize(width: 50, height: 0)),
            ("wide at rest, past its side", wide, 1, CGSize(width: 200, height: 0), CGSize(width: 75, height: 0)),
            ("tall at rest", tall, 1, CGSize(width: 80, height: -50), CGSize(width: 0, height: -50)),
            ("within reach", wide, 2, CGSize(width: -120, height: 60), CGSize(width: -120, height: 60)),
        ]
        for (what, image, scale, offset, settled) in cases {
            let moved = crop(image, scale: scale, offset: offset).settled.offset
            XCTAssertEqual(moved.width, settled.width, accuracy: 0.001, what)
            XCTAssertEqual(moved.height, settled.height, accuracy: 0.001, what)
        }
    }

    func testNoPanLeavesAGapInsideTheCircle() {
        let tolerance: CGFloat = 0.001
        for image in [wide, tall, square] {
            for scale: CGFloat in [1, 1.5, 2.5, 6] {
                for x in stride(from: CGFloat(-3_000), through: 3_000, by: 375) {
                    for y in stride(from: CGFloat(-3_000), through: 3_000, by: 375) {
                        let settled = crop(image, scale: scale, offset: CGSize(width: x, height: y)).settled
                        let what = "\(image) at \(scale) times, pushed \(x), \(y)"
                        let photo = settled.photoFrame
                        XCTAssertLessThanOrEqual(photo.minX, circle.minX + tolerance, what)
                        XCTAssertLessThanOrEqual(photo.minY, circle.minY + tolerance, what)
                        XCTAssertGreaterThanOrEqual(photo.maxX, circle.maxX - tolerance, what)
                        XCTAssertGreaterThanOrEqual(photo.maxY, circle.maxY - tolerance, what)
                        let kept = settled.kept
                        XCTAssertGreaterThanOrEqual(kept.minX, -tolerance, what)
                        XCTAssertGreaterThanOrEqual(kept.minY, -tolerance, what)
                        XCTAssertLessThanOrEqual(kept.maxX, image.width + tolerance, what)
                        XCTAssertLessThanOrEqual(kept.maxY, image.height + tolerance, what)
                        XCTAssertEqual(kept.width, kept.height, accuracy: tolerance, what)
                    }
                }
            }
        }
    }

    /// The square kept, drawn back where the photo is drawn, lands exactly on the circle.
    func testTheSquareKeptIsTheCircleDrawn() {
        let crops = [
            crop(wide),
            crop(tall, scale: 2, offset: CGSize(width: 90, height: -210)),
            crop(wide, scale: 3.3, offset: CGSize(width: -400, height: 120)),
        ]
        for crop in crops {
            let photo = crop.photoFrame
            let pointsPerPixel = photo.width / crop.imageSize.width
            let kept = crop.kept
            let drawn = CGRect(
                x: photo.minX + kept.minX * pointsPerPixel,
                y: photo.minY + kept.minY * pointsPerPixel,
                width: kept.width * pointsPerPixel,
                height: kept.height * pointsPerPixel
            )
            assertSame(drawn, circle, "\(crop.imageSize) at \(crop.scale) times, pushed \(crop.offset)")
        }
    }

    func testWhereTheCircleSitsOnScreenDoesNotChangeWhatItKeeps() {
        let offset = CGSize(width: 140, height: -90)
        let expected = crop(wide, scale: 2.5, offset: offset).kept
        for origin in [CGPoint(x: 0, y: 0), CGPoint(x: 37, y: 251), CGPoint(x: 200, y: 40)] {
            let moved = FaceCrop(
                imageSize: wide,
                circle: CGRect(origin: origin, size: circle.size),
                scale: 2.5,
                offset: offset
            )
            assertSame(moved.kept, expected, "circle at \(origin)")
        }
    }
}
