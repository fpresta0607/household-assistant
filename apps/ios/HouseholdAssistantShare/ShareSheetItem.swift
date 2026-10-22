// One thing being shared, as the Share Extension's sheet shows it before it is sent: a
// photo or a video by its picture, a file by its name, a link by its address, and text
// as itself.

import UIKit

struct ShareSheetItem: Identifiable {
    enum Kind {
        case photo, video, file, link, text
    }

    let id = UUID()
    let kind: Kind
    /// A file's name, a link's address without its scheme, or the text.
    let title: String
    /// A photo's or a video's picture, drawn small.
    var thumbnail: UIImage?
}
