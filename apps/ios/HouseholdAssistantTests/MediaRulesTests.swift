// The rules behind what a message carries: how several photos share one box, what a
// file is called on its card, and how much one message can take.

import Foundation
import XCTest
@testable import HouseholdAssistant

final class MediaRulesTests: XCTestCase {
    private func visual(_ width: Int? = nil, _ height: Int? = nil, kind: RoomMedia.Kind = .photo) -> RoomMedia {
        RoomMedia(id: String(repeating: "a", count: 64), kind: kind, mime: "image/jpeg", bytes: 10, width: width, height: height)
    }

    private func tile(_ index: Int, _ x: Double, _ y: Double, _ width: Double, _ height: Double) -> MediaGrid.Tile {
        MediaGrid.Tile(index: index, frame: CGRect(x: x, y: y, width: width, height: height))
    }

    func testOnePhotoOrVideoKeepsItsOwnShapeWithinBounds() {
        let shapes: [(width: Int?, height: Int?, kind: RoomMedia.Kind, aspect: Double)] = [
            (1600, 1000, .photo, 1.6),
            (900, 1600, .photo, 0.6),
            (4000, 1000, .photo, 1.8),
            (nil, nil, .photo, 4.0 / 3.0),
            (nil, nil, .video, 16.0 / 9.0),
            (1080, 1920, .video, 0.6),
        ]
        for shape in shapes {
            let grid = MediaGrid([visual(shape.width, shape.height, kind: shape.kind)])
            XCTAssertEqual(grid.aspect, shape.aspect, accuracy: 0.0001, "\(shape)")
            XCTAssertEqual(grid.tiles, [tile(0, 0, 0, 1, 1)])
            XCTAssertEqual(grid.overflow, 0)
        }
    }

    func testTwoWideOnesStackAndAnyOtherPairSitsSideBySide() {
        let wide = MediaGrid([visual(1600, 900), visual(1200, 900)])
        XCTAssertEqual(wide.tiles, [tile(0, 0, 0, 1, 0.5), tile(1, 0, 0.5, 1, 0.5)])
        XCTAssertEqual(wide.aspect, 3.0 / 4.0, accuracy: 0.0001)

        let mixed = MediaGrid([visual(1600, 900), visual(900, 1600)])
        XCTAssertEqual(mixed.tiles, [tile(0, 0, 0, 0.5, 1), tile(1, 0.5, 0, 0.5, 1)])
        XCTAssertEqual(mixed.aspect, 4.0 / 3.0, accuracy: 0.0001)
    }

    func testThreeAreOneWideOverTwo() {
        let grid = MediaGrid([visual(), visual(), visual()])
        XCTAssertEqual(grid.tiles, [tile(0, 0, 0, 1, 0.5), tile(1, 0, 0.5, 0.5, 0.5), tile(2, 0.5, 0.5, 0.5, 0.5)])
        XCTAssertEqual(grid.aspect, 1)
        XCTAssertEqual(grid.overflow, 0)
    }

    func testFourOrMoreAreTwoByTwoWithTheRestCountedOnTheLast() {
        let quarters = [tile(0, 0, 0, 0.5, 0.5), tile(1, 0.5, 0, 0.5, 0.5), tile(2, 0, 0.5, 0.5, 0.5), tile(3, 0.5, 0.5, 0.5, 0.5)]
        for (count, overflow) in [(4, 0), (6, 2), (10, 6)] {
            let grid = MediaGrid(Array(repeating: visual(), count: count))
            XCTAssertEqual(grid.tiles, quarters)
            XCTAssertEqual(grid.aspect, 1)
            XCTAssertEqual(grid.overflow, overflow)
        }
    }

    func testNothingToShowIsAnEmptyBox() {
        let grid = MediaGrid([])
        XCTAssertEqual(grid.tiles, [])
        XCTAssertEqual(grid.overflow, 0)
    }

    func testTheBoxFitsTheWidthUnlessThatMakesItTooTall() {
        XCTAssertEqual(MediaGrid([visual(1600, 1000)]).size(fitting: 240, maxHeight: 320), CGSize(width: 240, height: 150))
        XCTAssertEqual(MediaGrid([visual(900, 1600)]).size(fitting: 240, maxHeight: 320), CGSize(width: 192, height: 320))
        XCTAssertEqual(MediaGrid([visual(), visual(), visual(), visual()]).size(fitting: 240, maxHeight: 320), CGSize(width: 240, height: 240))
    }

    func testAFileIsLabelledByItsExtensionOrElseItsType() {
        let files: [(name: String?, mime: String, label: String)] = [
            ("Field trip permission slip.pdf", "application/pdf", "PDF"),
            ("Budget.xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "XLSX"),
            ("Rosa Marlowe.vcf", "text/vcard", "VCF"),
            ("archive.tar.gz", "application/gzip", "GZ"),
            (nil, "application/pdf", "PDF"),
            (nil, "application/json", "JSON"),
            ("notes", "text/plain", "FILE"),
            ("draft.", "application/octet-stream", "FILE"),
            ("photo.thumbnail-large", "image/x-unknown-format", "FILE"),
        ]
        for file in files {
            XCTAssertEqual(FileTypeLabel.label(name: file.name, mime: file.mime), file.label, "\(file)")
        }
    }

    func testAMessageTakesUpToTenAttachmentsOf50MBEachAnd120MBTogether() {
        let megabyte = 1024 * 1024
        XCTAssertNil(RoomAttachment.refusal(sizes: []))
        XCTAssertNil(RoomAttachment.refusal(sizes: [10]))
        XCTAssertNil(RoomAttachment.refusal(sizes: Array(repeating: 10, count: 10)))
        XCTAssertNil(RoomAttachment.refusal(sizes: [50 * megabyte, 50 * megabyte, 20 * megabyte]))
        XCTAssertEqual(RoomAttachment.refusal(sizes: Array(repeating: 10, count: 11)), "Up to ten things go in one message")
        XCTAssertEqual(RoomAttachment.refusal(sizes: [10, 50 * megabyte + 1]), "That is too large to send")
        XCTAssertEqual(RoomAttachment.refusal(sizes: [50 * megabyte, 50 * megabyte, 20 * megabyte + 1]), "Those are too large to send together")
    }
}
