// The thread's rows stacked top to bottom at the height each last drew at, the way
// Messages, Signal and Telegram lay out theirs (CFO notes section 21a). A row not drawn yet
// stands at its estimate (ThreadRowEstimate) until it is, so only rows near the screen are
// ever built. When a row draws at a height other than the one it stood at, the difference
// is taken up where the person does not see it: a row that starts above what they read
// moves the list by as much, so nothing they read moves, and at the newest the list stays
// at the bottom (ThreadCollectionView). A thread shorter than the screen sits at its
// bottom, just above the composer.

import UIKit

final class ThreadLayout: UICollectionViewLayout {
    /// Room around the rows.
    static let padding: CGFloat = 12

    /// The rows in order, by identity.
    var rows: [ThreadRow.ID] = []
    /// What each row not drawn yet stands at.
    var estimates: [ThreadRow.ID: CGFloat] = [:]
    /// Whether the list stands at its newest row, where it keeps the bottom instead.
    var isPinned: () -> Bool = { true }

    /// The height each row last drew at, at `measuredWidth`.
    private var heights: [ThreadRow.ID: CGFloat] = [:]
    private var measuredWidth: CGFloat = 0
    private var frames: [CGRect] = []
    private var contentHeight: CGFloat = 0

    /// The width a row is laid out at.
    var rowWidth: CGFloat {
        max(0, (collectionView?.bounds.width ?? 0) - 2 * Self.padding)
    }

    /// Whether `row` has drawn at the width the list has now.
    func hasHeight(_ row: ThreadRow.ID) -> Bool {
        heights[row] != nil
    }

    /// Every row draws again before its height is trusted, as when the text size changes.
    func forgetHeights() {
        heights = [:]
        invalidateLayout()
    }

    /// Lets go of the heights of rows no longer in the thread.
    func keepHeights(of kept: Set<ThreadRow.ID>) {
        heights = heights.filter { kept.contains($0.key) }
        estimates = estimates.filter { kept.contains($0.key) }
    }

    func frame(at index: Int) -> CGRect? {
        frames.indices.contains(index) ? frames[index] : nil
    }

    override func prepare() {
        super.prepare()
        guard let collectionView else {
            return
        }
        let width = collectionView.bounds.width
        if width != measuredWidth {
            heights = [:]
            measuredWidth = width
        }
        let rowWidth = self.rowWidth
        var top = Self.padding
        frames = rows.map { row in
            let height = heights[row] ?? estimates[row] ?? ThreadRowEstimate.lineHeight
            let frame = CGRect(x: Self.padding, y: top, width: rowWidth, height: height)
            top += height
            return frame
        }
        let rowsHeight = top + Self.padding
        let insets = collectionView.adjustedContentInset
        let lift = max(0, collectionView.bounds.height - insets.top - insets.bottom - rowsHeight)
        if lift > 0 {
            frames = frames.map { $0.offsetBy(dx: 0, dy: lift) }
        }
        contentHeight = rowsHeight + lift
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: collectionView?.bounds.width ?? 0, height: contentHeight)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        var found: [UICollectionViewLayoutAttributes] = []
        var index = firstIndex(endingAfter: rect.minY)
        while index < frames.count, frames[index].minY <= rect.maxY {
            found.append(attributes(at: index))
            index += 1
        }
        return found
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        frames.indices.contains(indexPath.item) ? attributes(at: indexPath.item) : nil
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.size != collectionView?.bounds.size
    }

    override func shouldInvalidateLayout(
        forPreferredLayoutAttributes preferred: UICollectionViewLayoutAttributes,
        withOriginalAttributes original: UICollectionViewLayoutAttributes
    ) -> Bool {
        abs(preferred.frame.height - original.frame.height) > 0.5
    }

    override func invalidationContext(
        forPreferredLayoutAttributes preferred: UICollectionViewLayoutAttributes,
        withOriginalAttributes original: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutInvalidationContext {
        let context = super.invalidationContext(forPreferredLayoutAttributes: preferred, withOriginalAttributes: original)
        let index = original.indexPath.item
        guard rows.indices.contains(index), let collectionView else {
            return context
        }
        heights[rows[index]] = preferred.frame.height
        // A row that starts above what the person reads grows or shrinks out of their sight.
        let visibleTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        let isAbove = !isPinned() && original.frame.minY < visibleTop
        if isAbove {
            context.contentOffsetAdjustment.y += preferred.frame.height - original.frame.height
        }
        ThreadLog.note(
            "measured \(index) \(rows[index]) \(original.frame.height)->\(preferred.frame.height) "
                + "at \(original.frame.minY) visible top \(visibleTop) pinned \(isPinned()) taken up above \(isAbove)"
        )
        return context
    }

    private func attributes(at index: Int) -> UICollectionViewLayoutAttributes {
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
        attributes.frame = frames[index]
        return attributes
    }

    /// The first row whose bottom is below `y`, by halving, or the count when none is.
    private func firstIndex(endingAfter y: CGFloat) -> Int {
        var low = 0
        var high = frames.count
        while low < high {
            let middle = (low + high) / 2
            if frames[middle].maxY <= y {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }
}
