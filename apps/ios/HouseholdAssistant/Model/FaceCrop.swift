// Where a face's photo sits under the crop circle, and which of its pixels the circle keeps.
//
// One rectangle decides everything: the circle, in the points of the screen that draws it.
// Where the photo is drawn, the outline, the hole in the dimming and the square of the
// photo kept all come from it, so what shows inside the circle is what is kept, as in
// Contacts. At scale 1 the photo just fills the circle, its short side across it, and the
// offset moves the photo's centre from the circle's. Plain numbers, so every rule is
// covered by a plain test.

import Foundation

struct FaceCrop {
    /// The photo's width and height in pixels, the right way up.
    var imageSize: CGSize
    /// The circle, in the view's points.
    var circle: CGRect
    /// 1 or more: 1 fills the circle with the photo's short side, 2 shows half as much.
    var scale: CGFloat
    /// The photo's centre from the circle's, in the view's points.
    var offset: CGSize

    /// Where the whole photo is drawn, in the view's points.
    var photoFrame: CGRect {
        let fill = max(circle.width / imageSize.width, circle.height / imageSize.height) * scale
        let width = imageSize.width * fill
        let height = imageSize.height * fill
        return CGRect(
            x: circle.midX + offset.width - width / 2,
            y: circle.midY + offset.height - height / 2,
            width: width,
            height: height
        )
    }

    /// The square of the photo the circle covers, in the photo's pixels: what is kept.
    var kept: CGRect {
        let photo = photoFrame
        let pixelsPerPoint = imageSize.width / photo.width
        return CGRect(
            x: (circle.minX - photo.minX) * pixelsPerPoint,
            y: (circle.minY - photo.minY) * pixelsPerPoint,
            width: circle.width * pixelsPerPoint,
            height: circle.height * pixelsPerPoint
        )
    }

    /// The photo moved back as little as it takes to cover the whole circle, so no pan
    /// leaves a gap inside it.
    var settled: FaceCrop {
        let photo = photoFrame
        let most = CGSize(width: (photo.width - circle.width) / 2, height: (photo.height - circle.height) / 2)
        var settled = self
        settled.offset = CGSize(
            width: min(max(offset.width, -most.width), most.width),
            height: min(max(offset.height, -most.height), most.height)
        )
        return settled
    }
}
