// The thread's scrolling list. While it stands at its newest row it stays there through
// whatever changes below or around it, a row arriving or growing, the keyboard and the
// composer rising and falling, in the same layout pass as the change, so the newest row is
// never drawn out of place for a frame (CFO notes section 21b). Only the person's own
// scrolling takes it away from the newest, or a message too tall to show whole there, which
// it shows from its top, and coming back there, or sending, pins it again.

import UIKit

final class ThreadCollectionView: UICollectionView {
    /// How near its newest row the list still stands at it.
    static let newestTolerance: CGFloat = 8

    /// Whether the list stands at its newest row.
    private(set) var isPinned = true
    /// Whether the list glides to its newest row, which pins it once there.
    private(set) var isGliding = false
    /// The part of the window no bar, composer or keyboard covers, which the rows are kept
    /// inside at rest.
    var uncovered = CGRect.zero
    /// Only while opening: UIKit can finish its first layout after SwiftUI's update.
    var onOpeningLayout: (() -> Void)?
    /// The way back to the newest row, kept over the list's own bottom trailing corner,
    /// where UIKit hands it the tap. Drawn over the list in SwiftUI, it never got one.
    var jumpControl: UIView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let jumpControl {
                jumpControl.isHidden = true
                jumpControl.alpha = 0
                addSubview(jumpControl)
            }
        }
    }
    private var isJumpShown = false
    private static let jumpSide: CGFloat = 44
    private static let jumpMargin: CGFloat = 16

    /// None above or below. The list keeps its rows clear of the bars and the composer by its
    /// insets, and a safe area here reached each row's SwiftUI content too, which then sat
    /// below the bars and measured taller by as much of the row as lay under them, so a row
    /// changed height with every point it scrolled and moved what the person read.
    override var safeAreaInsets: UIEdgeInsets {
        let given = super.safeAreaInsets
        return UIEdgeInsets(top: 0, left: given.left, bottom: 0, right: given.right)
    }

    /// The offset at which the newest row sits just above what is kept clear below.
    var newestOffset: CGFloat {
        max(-adjustedContentInset.top, contentSize.height + adjustedContentInset.bottom - bounds.height)
    }

    /// How far the list is above its newest row.
    var distanceFromNewest: CGFloat {
        newestOffset - contentOffset.y
    }

    /// How tall the part of the list nothing covers is.
    var visibleHeight: CGFloat {
        bounds.height - adjustedContentInset.top - adjustedContentInset.bottom
    }

    /// Keeps what lies outside `uncovered` clear of rows at rest, the bars above and the
    /// composer and keyboard below, and lays the list out again at once when that changed.
    func keepClearOfCovered() {
        if updateInsets() {
            layoutIfNeeded()
        }
    }

    /// Sets the insets from where this view is on screen against `uncovered`, and says
    /// whether they changed.
    private func updateInsets() -> Bool {
        guard window != nil, let superview, !uncovered.isEmpty else {
            return false
        }
        // From the frame, not the bounds, whose origin is the offset: converting those gave
        // insets a rounding apart at every offset, which laid the whole list out again.
        let onScreen = superview.convert(frame, to: nil)
        let insets = UIEdgeInsets(
            top: max(0, uncovered.minY - onScreen.minY),
            left: 0,
            bottom: max(0, onScreen.maxY - uncovered.maxY),
            right: 0
        )
        guard insets != contentInset else {
            return false
        }
        contentInset = insets
        verticalScrollIndicatorInsets = insets
        collectionViewLayout.invalidateLayout()
        return true
    }

    /// After the person's own scrolling, whether it left the list at the newest row.
    func notePersonScrolled() {
        isGliding = false
        let isAtNewest = distanceFromNewest <= Self.newestTolerance
        if isAtNewest != isPinned {
            ThreadLog.note("person scrolled, pinned \(isAtNewest) at \(contentOffset.y), \(distanceFromNewest) from the newest")
        }
        isPinned = isAtNewest
    }

    /// Lets go of the newest row, for a scroll that is not the person's finger but theirs all
    /// the same, as a tap on the status bar is.
    func letGo() {
        isPinned = false
        isGliding = false
    }

    /// Moves to the newest row and stays there, gliding unless `isAnimated` is false.
    func goToNewest(isAnimated: Bool) {
        isPinned = true
        isGliding = isAnimated
        layoutIfNeeded()
        let target = newestOffset
        ThreadLog.note("go to newest from \(contentOffset.y) to \(target) animated \(isAnimated)")
        guard isAnimated, abs(contentOffset.y - target) > 1 else {
            isGliding = false
            setNeedsLayout()
            layoutIfNeeded()
            return
        }
        setContentOffset(CGPoint(x: contentOffset.x, y: target), animated: true)
    }

    /// Brings a row that arrived too tall to show whole at the newest into view from its
    /// top, `top`, so it is read from the start, and lets go of the newest row below it.
    /// From `start`, where the list stood before the row arrived, it glides there unless
    /// `isAnimated` is false.
    func show(fromTop top: CGFloat, startingAt start: CGFloat, isAnimated: Bool) {
        isPinned = false
        isGliding = false
        let target = top - adjustedContentInset.top
        ThreadLog.note("show from top \(top), from \(start) to \(target) animated \(isAnimated)")
        guard isAnimated, target - start > 1 else {
            contentOffset.y = target
            return
        }
        contentOffset.y = start
        setContentOffset(CGPoint(x: contentOffset.x, y: target), animated: true)
    }

    /// Shows the way back to the newest row while the list stands well above it.
    func showJump(_ isShown: Bool, reducesMotion: Bool) {
        guard let jumpControl, isShown != isJumpShown else {
            return
        }
        isJumpShown = isShown
        if jumpControl.isHidden {
            jumpControl.transform = reducesMotion ? .identity : CGAffineTransform(scaleX: 0.6, y: 0.6)
        }
        jumpControl.isHidden = false
        UIView.animate(springDuration: reducesMotion ? 0.2 : 0.3, bounce: reducesMotion ? 0 : 0.16) {
            jumpControl.alpha = isShown ? 1 : 0
            jumpControl.transform = isShown || reducesMotion ? .identity : CGAffineTransform(scaleX: 0.6, y: 0.6)
        } completion: { [weak self] _ in
            jumpControl.isHidden = !(self?.isJumpShown ?? false)
        }
    }

    /// The glide reached the newest row, or the person's finger stopped it.
    func endGlide() {
        ThreadLog.note("glide ended at \(contentOffset.y), \(distanceFromNewest) from the newest")
        isGliding = false
        setNeedsLayout()
    }

    override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
        if isGliding, !animated {
            // A move at once ends the glide with no word that it ended, which left the list
            // short of the newest row and no longer pinned to it.
            ThreadLog.note("glide cut short at \(self.contentOffset.y) by a move to \(contentOffset.y)")
            isGliding = false
            setNeedsLayout()
        }
        // UIKit moves the list itself when its content shrinks, animated inside an animation,
        // as when a message is lifted for its menu. At the newest the pin is where the list
        // belongs, so that move happens at once rather than racing the pin frame by frame.
        super.setContentOffset(contentOffset, animated: animated && (isGliding || !isPinned))
    }

    override func layoutSubviews() {
        // On its first pass in a window, and whenever its frame moved, the insets follow.
        _ = updateInsets()
        super.layoutSubviews()
        if isPinned, !isGliding, !isTracking, !isDecelerating {
            // A row that took its height in this pass may have moved the newest row again, so
            // once more at most.
            for _ in 0..<2 {
                let target = newestOffset
                guard abs(contentOffset.y - target) > 0.5 else {
                    break
                }
                ThreadLog.note("pinned \(contentOffset.y)->\(target) content \(contentSize.height) insets \(adjustedContentInset.top) \(adjustedContentInset.bottom)")
                contentOffset.y = target
                super.layoutSubviews()
            }
        }
        if let jumpControl {
            // By its center, which a transform leaves alone, just above what is kept clear below.
            let side = Self.jumpSide
            jumpControl.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            jumpControl.center = CGPoint(
                x: bounds.maxX - Self.jumpMargin - side / 2,
                y: bounds.maxY - adjustedContentInset.bottom - Self.jumpMargin - side / 2
            )
            bringSubviewToFront(jumpControl)
        }
        #if DEBUG
        // The part of the list nothing covers, on screen, where the timestamps are measured too.
        if DemoLongMessages.isRequested {
            DemoTimestampObservation.shared.viewport = convert(bounds.inset(by: adjustedContentInset), to: nil)
        }
        #endif
        onOpeningLayout?()
    }
}
