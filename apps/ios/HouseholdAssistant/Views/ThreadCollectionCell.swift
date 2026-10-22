// One place in the thread's list, showing a row by holding the view of the row's own host
// (ThreadRowHost), which the row keeps when the cell goes on to show another. The row is
// measured at the cell's width, and its height is the one it drew at.

import UIKit

final class ThreadCollectionCell: UICollectionViewCell {
    /// The row's host the cell shows.
    private(set) var host: ThreadRowHost?
    var isDisplaying = false {
        didSet { host?.visibility.isVisible = isDisplaying }
    }

    /// Shows the row `host` holds, taking its view from any cell that showed it before.
    func hold(_ host: ThreadRowHost) {
        guard host !== self.host else {
            return
        }
        if let held = self.host {
            letGo(of: held)
        }
        host.cell?.letGo(of: host)
        self.host = host
        host.cell = self
        host.visibility.isVisible = isDisplaying
        contentView.addSubview(host.controller.view)
        joinControllers()
        setNeedsLayout()
    }

    /// Stops showing `host`'s row, which keeps its view for the next cell that shows it.
    func letGo(of host: ThreadRowHost) {
        guard host === self.host else {
            return
        }
        host.visibility.isVisible = false
        host.controller.view.removeFromSuperview()
        host.cell = nil
        self.host = nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        joinControllers()
    }

    /// In the view controllers' tree, so what a row presents, as a card's Share does, has a
    /// controller to present from.
    private func joinControllers() {
        guard window != nil, let controller = host?.controller, controller.parent == nil else {
            return
        }
        var responder = next
        while let current = responder, !(current is UIViewController) {
            responder = current.next
        }
        if let parent = responder as? UIViewController {
            parent.addChild(controller)
            controller.didMove(toParent: parent)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Always the cell's own size. Left to resize with the cell, it kept the size it was
        // measured at, and the row, drawn from its bottom, stood that much off its cell.
        host?.controller.view.frame = contentView.bounds
    }

    override func preferredLayoutAttributesFitting(
        _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        guard let host else {
            return layoutAttributes
        }
        #if DEBUG
        let start = CACurrentMediaTime()
        defer {
            ThreadFlingLog.shared.built(host.flingKind, since: start)
        }
        #endif
        // Drawn at the row's width now, so the height it says is for that width, then back
        // to the cell's size once the cell takes its new one.
        let height = host.measure(at: layoutAttributes.size)
        setNeedsLayout()
        if let height {
            layoutAttributes.size.height = height
        }
        return layoutAttributes
    }
}
