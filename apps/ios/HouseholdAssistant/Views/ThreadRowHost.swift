// One row of the thread, its SwiftUI view in a hosting controller of its own that stays
// with the row while it is near the screen (ThreadCollectionCoordinator). A cell shows the
// row by holding its view, so a row that scrolls away and back, or comes on screen in a
// cell that showed another row, is not built again. Building rows as they came on screen
// was what a fast fling up paid for: a long reply took 60 to 125 ms to build in a cell
// that had shown another row, a chart about 30, and a row its cell still held nothing
// (FastFlingTests, CFO notes section 3).
//
// The row says how tall it drew, and that is its height. A hosting configuration measured
// it instead, offered the height it stood at, so a message's text shrank to that, cut short
// with an ellipsis at large text sizes, and a reply that grew drew outside its cell, as far
// above as below, until the next pass: its bottom dipped half a line with each new line.
// Here the row is drawn from its bottom, so one that grows keeps its bottom edge and grows
// upward until the list makes room. It sees no safe area and no keyboard, which the list
// keeps it clear of by its insets (ThreadCollectionView).

import SwiftUI
import UIKit

/// UIKit owns chat scrolling, so SwiftUI's scroll-visibility callbacks do not fire here.
@Observable @MainActor
final class ThreadRowVisibility {
    var isVisible = false
}

private struct ThreadRowVisibilityKey: EnvironmentKey {
    static let defaultValue: ThreadRowVisibility? = nil
}

extension EnvironmentValues {
    var threadRowVisibility: ThreadRowVisibility? {
        get { self[ThreadRowVisibilityKey.self] }
        set { self[ThreadRowVisibilityKey.self] = newValue }
    }
}

@MainActor
final class ThreadRowHost {
    let controller = UIHostingController(rootView: AnyView(EmptyView()))
    let visibility = ThreadRowVisibility()
    /// The row as it was last built, and the look it was built in (ThreadCollectionCoordinator).
    private(set) var row: ThreadRow?
    private(set) var look = 0
    /// How tall the row drew at the width it was last laid out at, once it has.
    private(set) var drawnHeight: CGFloat?
    /// The cell showing the row, told when the row draws at a new height by itself.
    weak var cell: ThreadCollectionCell?
    /// The screen's points per pixel, which heights are rounded up to.
    private let scale: CGFloat
    private var isMeasuring = false
    #if DEBUG
    /// What the row is, for the fling's cost (ThreadFlingLog).
    private(set) var flingKind = ""
    #endif

    init(scale: CGFloat) {
        self.scale = max(scale, 1)
        controller.safeAreaRegions = []
        controller.view.backgroundColor = .clear
    }

    func show(_ row: ThreadRow, look: Int, as content: some View) {
        self.row = row
        self.look = look
        #if DEBUG
        flingKind = ThreadLog.isShown ? ThreadFlingLog.kind(of: row) : ""
        #endif
        controller.rootView = AnyView(
            content
                .environment(\.threadRowVisibility, visibility)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.size.height
                } action: { [weak self] height in
                    self?.drew(at: height)
                }
                .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .bottom)
        )
    }

    /// Lays the row out at `size` and says how tall it drew.
    func measure(at size: CGSize) -> CGFloat? {
        isMeasuring = true
        controller.view.frame = CGRect(origin: .zero, size: size)
        controller.view.layoutIfNeeded()
        isMeasuring = false
        return drawnHeight
    }

    /// Lets go of the row for good: out of its cell and out of the controllers' tree.
    func release() {
        visibility.isVisible = false
        cell?.letGo(of: self)
        controller.willMove(toParent: nil)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
    }

    private func drew(at height: CGFloat) {
        let height = (height * scale).rounded(.up) / scale
        guard height != drawnHeight else {
            return
        }
        #if DEBUG
        if !isMeasuring {
            ThreadFlingLog.shared.drewLate(flingKind, isFirst: drawnHeight == nil)
        }
        #endif
        drawnHeight = height
        if !isMeasuring {
            // The collection view measures the cell again and moves what follows.
            cell?.invalidateIntrinsicContentSize()
        }
    }
}
