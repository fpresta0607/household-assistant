// How tall a row of the thread will stand before it has drawn, worked out from what it
// holds, so the list can place the rows it has not built yet (ThreadLayout). It only has to
// be near: once a row draws, its real height takes over, and the list takes up the
// difference where the person does not see it.

import Foundation

enum ThreadRowEstimate {
    /// About how tall a line of a bubble's words stands.
    static let lineHeight: CGFloat = 22
    /// About how wide a character of the body text is.
    static let characterWidth: CGFloat = 8
    /// A bubble's padding around its words, top and bottom together.
    static let bubblePadding: CGFloat = 20
    /// How much of the row a bubble's words may take.
    static let bubbleShare: CGFloat = 0.78
    static let cardHeight: CGFloat = 180
    static let pictureHeight: CGFloat = 240
    static let voiceNoteHeight: CGFloat = 56
    static let fileHeight: CGFloat = 64
    static let callHeight: CGFloat = 60
    static let receiptHeight: CGFloat = 18

    /// The height `row` will about stand at in a list `width` points wide.
    static func height(of row: ThreadRow, width: CGFloat) -> CGFloat {
        switch row.content {
        case .older:
            44
        case .hello:
            200
        case .typing:
            56
        case .shared:
            64
        case .look:
            36
        case .message(let content):
            height(of: content, width: width)
        }
    }

    private static func height(of content: ThreadRow.Message, width: CGFloat) -> CGFloat {
        let message = content.message
        var height: CGFloat = content.placement.divider != nil ? 40 : (content.placement.startsRun ? 12 : 4)
        if content.readers != nil {
            height += receiptHeight
        }
        if message.call != nil {
            return height + callHeight
        }
        let perLine = max(1, Int((width * bubbleShare - bubblePadding) / characterWidth))
        var lines = 0
        var cards = 0
        // Between fences every other stretch is fenced: a card stands at a card's height, and
        // any other fenced block is read as lines.
        for (index, stretch) in message.text.components(separatedBy: "```").enumerated() {
            if index % 2 == 1, stretch.hasPrefix("steward-card") {
                cards += 1
                continue
            }
            for line in stretch.split(separator: "\n") {
                lines += (line.count + perLine - 1) / perLine
            }
        }
        if lines > 0 {
            height += CGFloat(lines) * lineHeight + bubblePadding
        }
        height += CGFloat(cards) * cardHeight
        if message.media.contains(where: \.kind.isVisual) {
            height += pictureHeight
        }
        height += CGFloat(message.media.filter { $0.kind == .voice }.count) * voiceNoteHeight
        height += CGFloat(message.media.filter { $0.kind == .file }.count) * fileHeight
        return height
    }
}
