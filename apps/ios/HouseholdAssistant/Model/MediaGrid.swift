// How the photos and videos of one message share their box: one at its own shape, two
// one above the other when both are wide and side by side otherwise, three as one wide
// over two, and four or more as two by two with the rest counted on the last.
//
// The box's shape comes from the width and height each attachment carries, so it is
// drawn at its final size before a single byte of the picture has arrived.

import Foundation

struct MediaGrid: Equatable {
    struct Tile: Equatable {
        /// Which of the message's photos and videos it shows.
        let index: Int
        /// Where it sits, in fractions of the box.
        let frame: CGRect
    }

    let tiles: [Tile]
    /// The box's width over its height.
    let aspect: Double
    /// How many more there are than the tiles show, counted on the last tile.
    let overflow: Int

    /// The narrowest and widest a lone photo is drawn; anything beyond is cropped.
    static let aspects = 0.6...1.8

    init(_ media: [RoomMedia]) {
        let half = 0.5
        switch media.count {
        case 0:
            tiles = []
            aspect = 1
        case 1:
            tiles = [Tile(index: 0, frame: CGRect(x: 0, y: 0, width: 1, height: 1))]
            aspect = Self.aspect(of: media[0])
        case 2 where media.allSatisfy({ Self.aspect(of: $0) > 1 }):
            tiles = [
                Tile(index: 0, frame: CGRect(x: 0, y: 0, width: 1, height: half)),
                Tile(index: 1, frame: CGRect(x: 0, y: half, width: 1, height: half)),
            ]
            aspect = 3.0 / 4.0
        case 2:
            tiles = [
                Tile(index: 0, frame: CGRect(x: 0, y: 0, width: half, height: 1)),
                Tile(index: 1, frame: CGRect(x: half, y: 0, width: half, height: 1)),
            ]
            aspect = 4.0 / 3.0
        case 3:
            tiles = [
                Tile(index: 0, frame: CGRect(x: 0, y: 0, width: 1, height: half)),
                Tile(index: 1, frame: CGRect(x: 0, y: half, width: half, height: half)),
                Tile(index: 2, frame: CGRect(x: half, y: half, width: half, height: half)),
            ]
            aspect = 1
        default:
            tiles = (0..<4).map { index in
                Tile(index: index, frame: CGRect(x: Double(index % 2) * half, y: Double(index / 2) * half, width: half, height: half))
            }
            aspect = 1
        }
        overflow = max(media.count - 4, 0)
    }

    /// A photo's or video's own shape, kept within `aspects`. One that never said its
    /// size is drawn as a photo or a video usually is.
    static func aspect(of media: RoomMedia) -> Double {
        guard let width = media.width, let height = media.height, width > 0, height > 0 else {
            return media.kind == .video ? 16.0 / 9.0 : 4.0 / 3.0
        }
        return min(max(Double(width) / Double(height), aspects.lowerBound), aspects.upperBound)
    }

    /// The box at `width`, or shorter and narrower when that would be taller than `maxHeight`.
    func size(fitting width: CGFloat, maxHeight: CGFloat) -> CGSize {
        let height = width / CGFloat(aspect)
        guard height > maxHeight else {
            return CGSize(width: width, height: height)
        }
        return CGSize(width: maxHeight * CGFloat(aspect), height: maxHeight)
    }
}
