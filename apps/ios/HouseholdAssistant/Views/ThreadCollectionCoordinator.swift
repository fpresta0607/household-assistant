// Feeds the thread's collection view from the room's rows. Each update finds the rows by
// identity, so only a row whose content changed draws again and every row keeps the height
// it drew at (ThreadLayout). Rows coming or going above what the person reads leave the
// message they read where it is. At the newest, a row arriving at the bottom takes its place
// just above the composer in the same pass and fades in, and what this phone sends rises
// out of its own corner, as in Messages, never from under the composer. A message from
// someone else too tall to show whole there glides up from where the list stood until its
// top is at the top instead, so it is read from the start. What this phone sends brings the
// list to it from wherever the person was. The page before is read once its row comes on
// screen.
//
// Each row is built once in a host of its own (ThreadRowHost) and kept while it is near
// the screen, so a row is built again only when what it shows changes. While the list
// rests, the rows just ahead of the screen are built too, nearest first, the most above,
// where a fling up goes, so a fast fling meets rows already built (CFO notes section 3).
// Rows far from the screen are let go, and all but those on screen when memory runs low.

import SwiftUI
import UIKit

@MainActor
final class ThreadCollectionCoordinator: NSObject, UICollectionViewDelegate {
    /// What the rows draw with that can change while the thread stays open, the rims
    /// and the current theme. Rows built before a theme switch must be configured again.
    private struct Look: Equatable {
        let colorScheme: ColorScheme
        let dynamicTypeSize: DynamicTypeSize
        let legibilityWeight: LegibilityWeight?
        let readingStyle: ReadingStyle
        let reducesMotion: Bool
        let rims: RimLook
    }

    /// How far ahead of the screen rows are built while the list rests, in screens: above,
    /// where a fling up goes, and below.
    private static let screensAheadAbove: CGFloat = 6
    private static let screensAheadBelow: CGFloat = 1.5
    /// How many rows stay built while the list rests. A fling builds every row it passes,
    /// and lets go of the farthest once twice as many are built.
    private static let keptRows = 80
    private static let restBeforeBuildingAhead: TimeInterval = 0.5

    let layout = ThreadLayout()
    private var list: ThreadCollection
    private var dataSource: UICollectionViewDiffableDataSource<Int, ThreadRow.ID>?
    private weak var view: ThreadCollectionView?
    private var rows: [ThreadRow.ID: ThreadRow] = [:]
    private var order: [ThreadRow.ID] = []
    private var environment = EnvironmentValues()
    private var look: Look?
    /// The rows the last update brought in, which fade in as they show.
    private var arriving: Set<ThreadRow.ID> = []
    /// The rows that left the screen since they were last shown. Their voice notes show only
    /// themselves when they come back, closed before the row is measured, so a note never
    /// comes back at a height the list did not lay it out at (VoiceNoteDisclosures).
    private var leftScreen: Set<ThreadRow.ID> = []
    private var isReadingOlder = false
    /// The jump back to the newest row, in the list's own corner (ThreadCollectionView).
    private let jump = UIHostingController(rootView: AnyView(EmptyView()))
    private var isFarFromNewest = false
    /// Each row's own host, while the row is near the screen.
    private var hosts: [ThreadRow.ID: ThreadRowHost] = [:]
    /// Counts the looks the rows were drawn in, so a row built in an older one is built again.
    private var lookCount = 0
    private var isBuildingAhead = false
    private var hasRevealed = false
    private var opening: Task<Void, Never>?
    private var isOpeningCheckQueued = false
    /// Where a row built ahead is laid out: hidden in the list, so in the window, as on screen.
    private let shelf = UIView()
    #if DEBUG
    private var builtAhead = 0
    private var builtAheadMilliseconds: Double = 0
    #endif

    init(list: ThreadCollection) {
        self.list = list
        super.init()
        layout.isPinned = { [weak self] in
            self?.view?.isPinned ?? true
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(memoryRanLow),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }

    func attach(to view: ThreadCollectionView) {
        self.view = view
        // Keep the chat's background visible while its first rows are being prepared.
        // Alpha preserves layout, unlike removing the list or hiding its cells.
        view.alpha = 0
        view.accessibilityElementsHidden = true
        view.isUserInteractionEnabled = false
        view.onOpeningLayout = { [weak self] in self?.checkOpeningAfterLayout() }
        let registration = UICollectionView.CellRegistration<ThreadCollectionCell, ThreadRow.ID> { [unowned self] cell, _, row in
            self.configure(cell, for: row)
        }
        dataSource = UICollectionViewDiffableDataSource<Int, ThreadRow.ID>(collectionView: view) { collectionView, indexPath, row in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: row)
        }
        view.delegate = self
        list.state.rowAt = { [weak self, weak view] point in
            guard let self, let view, let path = view.indexPathForItem(at: view.convert(point, from: nil)),
                  let id = self.dataSource?.itemIdentifier(for: path), case .message? = self.rows[id]?.content else { return nil }
            return id
        }
        jump.safeAreaRegions = []
        jump.view.backgroundColor = .clear
        view.jumpControl = jump.view
        shelf.isHidden = true
        view.addSubview(shelf)
    }

    func update(_ list: ThreadCollection, environment: EnvironmentValues) {
        #if DEBUG
        let start = CACurrentMediaTime()
        defer {
            ThreadFlingLog.shared.passed("list", since: start)
        }
        #endif
        let previous = self.list
        self.list = list
        self.environment = environment
        jump.rootView = AnyView(
            JumpToNewestButton { [weak self] in
                ThreadLog.note("jump tapped")
                if let returnToLatest = self?.list.returnToLatest {
                    returnToLatest()
                } else {
                    self?.view?.goToNewest(isAnimated: !(self?.look?.reducesMotion ?? false))
                }
            }
            .environment(\.self, environment)
        )
        let look = Look(
            colorScheme: environment.colorScheme,
            dynamicTypeSize: environment.dynamicTypeSize,
            legibilityWeight: environment.legibilityWeight,
            readingStyle: environment.readingStyle,
            reducesMotion: environment.reducesMotion,
            rims: environment.rims
        )
        let isNewLook = self.look.map { $0 != look } ?? false
        if look != self.look {
            ThreadLog.note("rows drawn with themes \(look.rims.theme.rawValue)")
        }
        self.look = look
        if isNewLook {
            lookCount += 1
            letGoOfRowsOffScreen()
            layout.forgetHeights()
        }
        apply(list.rows, isNewLook: isNewLook)
        if let own = list.newestOwnBubble, own != previous.newestOwnBubble {
            view?.goToNewest(isAnimated: !look.reducesMotion)
        }
        if let found = list.jump, found != previous.jump {
            bringIntoView(message: found.messageId)
        }
        prepareOpening()
    }

    /// The first update may arrive before a window, bounds or visible cells exist.
    /// Retry after UIKit lays them out, outside that layout pass to avoid reentrancy.
    private func checkOpeningAfterLayout() {
        guard !hasRevealed, opening == nil, !isOpeningCheckQueued else { return }
        isOpeningCheckQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer { isOpeningCheckQueued = false }
            guard view?.onOpeningLayout != nil else { return }
            prepareOpening()
        }
    }

    /// Prepare just what the uncovered screen shows. Re-measure while concealed, since
    /// formatted text changes both the row heights and which rows fit above the newest.
    private func prepareOpening() {
        guard !hasRevealed, opening == nil, let view, view.window != nil,
              !view.uncovered.isEmpty, !order.isEmpty else { return }
        view.layoutIfNeeded()
        guard let preparation = list.preparation else {
            revealOpening(animated: false)
            return
        }
        let visible = openingMessages(in: view)
        guard !visible.isEmpty else { return }
        if preparation.isReady(visible) {
            revealOpening(animated: false)
            return
        }
        opening = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { opening = nil }
            // Formatting can expose a different row after layout. The bounded passes
            // also prevent an exceptionally large document from holding the screen forever.
            for _ in 0..<4 {
                guard !Task.isCancelled, let view = self.view, view.window != nil,
                      let preparation = list.preparation else { return }
                let visible = openingMessages(in: view)
                await preparation.prepare(visible)
                guard !Task.isCancelled else { return }
                // Read the completed documents from the cache before the first paint.
                lookCount += 1
                for path in view.indexPathsForVisibleItems where order.indices.contains(path.item) {
                    if let row = rows[order[path.item]], let cell = view.cellForItem(at: path) as? ThreadCollectionCell {
                        cell.hold(host(for: row))
                    }
                }
                layout.forgetHeights()
                view.setNeedsLayout()
                view.layoutIfNeeded()
                // Allow the hosting controllers' measured heights to reach the layout.
                await Task.yield()
                guard !Task.isCancelled else { return }
                view.layoutIfNeeded()
                if preparation.isReady(openingMessages(in: view)) { break }
            }
            guard !Task.isCancelled else { return }
            revealOpening(animated: true)
        }
    }

    private func openingMessages(in view: ThreadCollectionView) -> [RoomMessage] {
        let span = visibleSpan(of: view)
        return view.indexPathsForVisibleItems.sorted().compactMap { path in
            guard order.indices.contains(path.item), let frame = layout.frame(at: path.item),
                  frame.maxY > span.lowerBound, frame.minY < span.upperBound,
                  case .message(let content)? = rows[order[path.item]]?.content else { return nil }
            return content.message
        }
    }

    private func revealOpening(animated: Bool) {
        guard !hasRevealed, let view else { return }
        hasRevealed = true
        view.onOpeningLayout = nil
        view.accessibilityElementsHidden = false
        view.isUserInteractionEnabled = true
        if animated, !(look?.reducesMotion ?? false) {
            UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
                view.alpha = 1
            }
        } else {
            view.alpha = 1
        }
        ThreadLog.note("opening revealed at newest \(view.isPinned)")
        buildAhead()
    }

    /// Brings a message a search found into view in one move (CFO notes section 5): its top
    /// a quarter of the way down what shows, or higher for one that would not fit whole
    /// there, with the rows round it built and measured in the same pass and the list set
    /// again until the message stands where it was asked to, before anything is drawn.
    private func bringIntoView(message id: String) {
        guard let view, let index = order.firstIndex(where: { row in
            if case .message(let content)? = rows[row]?.content {
                return content.message.id == id
            }
            return false
        }) else {
            ThreadLog.note("search found no row for its message")
            return
        }
        view.letGo()
        for _ in 0..<4 {
            view.layoutIfNeeded()
            guard let frame = layout.frame(at: index) else {
                return
            }
            let lead = min(view.visibleHeight / 4, max(0, (view.visibleHeight - frame.height) / 2))
            let target = min(max(frame.minY - lead - view.adjustedContentInset.top, -view.adjustedContentInset.top), view.newestOffset)
            guard abs(view.contentOffset.y - target) > 0.5 else {
                break
            }
            view.contentOffset.y = target
        }
        view.notePersonScrolled()
        noteStanding(of: view)
        ThreadLog.note("search brought row \(index) into view at \(view.contentOffset.y)")
    }

    // MARK: - Rows

    private func apply(_ newRows: [ThreadRow], isNewLook: Bool) {
        guard let view, let dataSource else {
            return
        }
        let newOrder = newRows.map(\.id)
        var next: [ThreadRow.ID: ThreadRow] = [:]
        next.reserveCapacity(newRows.count)
        var changed: [ThreadRow.ID] = []
        for row in newRows {
            if let old = rows[row.id], isNewLook || old != row {
                changed.append(row.id)
            }
            next[row.id] = row
        }
        let isFirst = order.isEmpty
        guard isFirst || newOrder != order || !changed.isEmpty else {
            return
        }
        let offsetBefore = view.contentOffset.y
        let heightBefore = view.contentSize.height
        let countBefore = order.count
        let wasPinned = view.isPinned
        // Where the person reads, from the rows as they stand before the change.
        let anchor = wasPinned ? nil : readingAnchor(in: view)
        let previousRows = Set(order)
        arriving = isFirst ? [] : Set(newOrder.filter { !previousRows.contains($0) })
        // Kept apart, since each row's fade takes it out of `arriving` as it shows.
        let arrived = arriving
        rows = next
        order = newOrder
        layout.rows = newOrder
        if previousRows.count + arriving.count > newOrder.count {
            layout.keepHeights(of: Set(newOrder))
            for id in Array(hosts.keys) where next[id] == nil {
                hosts.removeValue(forKey: id)?.release()
            }
        }
        let width = max(layout.rowWidth, 320)
        let changedRows = Set(changed)
        for row in newRows where !layout.hasHeight(row.id) && (layout.estimates[row.id] == nil || changedRows.contains(row.id)) {
            layout.estimates[row.id] = ThreadRowEstimate.height(of: row, width: width)
        }

        var snapshot = NSDiffableDataSourceSnapshot<Int, ThreadRow.ID>()
        snapshot.appendSections([0])
        snapshot.appendItems(newOrder, toSection: 0)
        snapshot.reconfigureItems(changed)
        dataSource.apply(snapshot, animatingDifferences: false)
        view.layoutIfNeeded()
        let offsetApplied = view.contentOffset.y
        if let anchor {
            restore(anchor, in: view)
        }
        if wasPinned, let top = topOfTallArrival(among: arrived, in: view) {
            view.show(fromTop: top, startingAt: offsetBefore, isAnimated: !(look?.reducesMotion ?? false))
        }
        ThreadLog.note(
            "apply rows \(countBefore)->\(newOrder.count) arriving \(arriving.count) changed \(changed.count) \(changed.prefix(3)) "
                + "pinned \(view.isPinned) offset \(offsetBefore)->\(offsetApplied)->\(view.contentOffset.y) "
                + "content \(heightBefore)->\(view.contentSize.height) anchor \(anchor.map { "\($0.row) at \($0.top)" } ?? "none")"
        )
        // Only what came in with this update and showed in it fades in, not a row reached later.
        arriving = []
        noteStanding(of: view)
        buildAhead()
    }

    private func configure(_ cell: ThreadCollectionCell, for id: ThreadRow.ID) {
        guard let row = rows[id] else {
            return
        }
        if leftScreen.remove(id) != nil, case .message(let content) = row.content, list.state.voiceNotes.showsAny(of: content.message.id) {
            list.state.voiceNotes.close(of: content.message.id)
        }
        cell.hold(host(for: row))
    }

    /// The row's host, built anew when what the row shows or the look changed since it was.
    private func host(for row: ThreadRow) -> ThreadRowHost {
        let host: ThreadRowHost
        if let kept = hosts[row.id] {
            host = kept
        } else {
            host = ThreadRowHost(scale: view?.traitCollection.displayScale ?? 1)
            hosts[row.id] = host
            if hosts.count > Self.keptRows * 2 {
                letGoOfFarRows(keeping: Self.keptRows)
            }
        }
        if host.row != row || host.look != lookCount {
            #if DEBUG
            let start = CACurrentMediaTime()
            #endif
            host.show(
                row,
                look: lookCount,
                as: ThreadCell(row: row, conversation: list.conversation, actions: list.actions, state: list.state)
                    .environment(\.self, environment)
            )
            #if DEBUG
            ThreadFlingLog.shared.built(host.flingKind + " shown", since: start)
            #endif
        }
        return host
    }

    // MARK: - Rows ahead

    /// Builds the rows just ahead of the screen once the list has rested a moment, so the
    /// push that opens a thread or a quick next touch never waits on them, then one each
    /// turn of the main queue, so what is on screen keeps moving between them.
    private func buildAhead() {
        guard hasRevealed, !isBuildingAhead else {
            return
        }
        isBuildingAhead = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restBeforeBuildingAhead) { [weak self] in
            self?.buildNextAhead()
        }
    }

    private func buildNextAhead() {
        guard let view, view.window != nil, !view.isTracking, !view.isDecelerating, !view.isGliding,
              let next = nextRowAhead(in: view) else {
            isBuildingAhead = false
            #if DEBUG
            if builtAhead > 0 {
                ThreadLog.note("built ahead \(builtAhead) rows in \(Int(builtAheadMilliseconds)) ms, \(hosts.count) kept")
                builtAhead = 0
                builtAheadMilliseconds = 0
            }
            #endif
            return
        }
        #if DEBUG
        let start = CACurrentMediaTime()
        #endif
        let ahead = host(for: next)
        shelf.addSubview(ahead.controller.view)
        _ = ahead.measure(at: CGSize(width: layout.rowWidth, height: ThreadRowEstimate.lineHeight))
        ahead.controller.view.removeFromSuperview()
        #if DEBUG
        builtAhead += 1
        builtAheadMilliseconds += (CACurrentMediaTime() - start) * 1000
        #endif
        DispatchQueue.main.async { [weak self] in
            self?.buildNextAhead()
        }
    }

    /// The nearest row ahead of the screen not built yet, making room for it by letting go
    /// of a farther one when as many rows as are kept are built. Nil when all are built.
    private func nextRowAhead(in view: ThreadCollectionView) -> ThreadRow? {
        let screen = visibleSpan(of: view)
        let above = screen.lowerBound - view.visibleHeight * Self.screensAheadAbove
        let below = screen.upperBound + view.visibleHeight * Self.screensAheadBelow
        var nearest: (row: ThreadRow, distance: CGFloat)?
        for (index, id) in order.enumerated() where hosts[id] == nil {
            guard let frame = layout.frame(at: index), frame.maxY >= above, frame.minY <= below, let row = rows[id] else {
                continue
            }
            let distance = Self.distance(of: frame, from: screen)
            if distance < nearest?.distance ?? .infinity {
                nearest = (row, distance)
            }
        }
        guard let nearest else {
            return nil
        }
        if hosts.count >= Self.keptRows {
            let places = rowPlaces()
            let farthest = hosts.keys.max { first, second in
                distance(ofRowAt: places[first], from: screen) < distance(ofRowAt: places[second], from: screen)
            }
            guard let farthest, distance(ofRowAt: places[farthest], from: screen) > nearest.distance else {
                return nil
            }
            hosts.removeValue(forKey: farthest)?.release()
        }
        return nearest.row
    }

    /// Lets go of the rows farthest from the screen until only `limit` are built.
    private func letGoOfFarRows(keeping limit: Int) {
        guard hosts.count > limit, let view else {
            return
        }
        let screen = visibleSpan(of: view)
        let places = rowPlaces()
        let farthestFirst = hosts.keys.sorted { first, second in
            distance(ofRowAt: places[first], from: screen) > distance(ofRowAt: places[second], from: screen)
        }
        for id in farthestFirst.prefix(hosts.count - limit) {
            hosts.removeValue(forKey: id)?.release()
        }
    }

    /// Lets go of every row but those on screen.
    private func letGoOfRowsOffScreen() {
        guard let view else {
            return
        }
        let shown = Set(view.indexPathsForVisibleItems.compactMap { order.indices.contains($0.item) ? order[$0.item] : nil })
        for id in Array(hosts.keys) where !shown.contains(id) {
            hosts.removeValue(forKey: id)?.release()
        }
    }

    @objc private func memoryRanLow() {
        letGoOfRowsOffScreen()
    }

    /// The thread closed: every row is let go, out of the controllers' tree too.
    func letGoOfAllRows() {
        view?.onOpeningLayout = nil
        opening?.cancel()
        opening = nil
        for host in hosts.values {
            host.release()
        }
        hosts = [:]
    }

    /// Where each row is in the thread.
    private func rowPlaces() -> [ThreadRow.ID: Int] {
        Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
    }

    /// The part of the list's content nothing covers.
    private func visibleSpan(of view: ThreadCollectionView) -> ClosedRange<CGFloat> {
        let top = view.contentOffset.y + view.adjustedContentInset.top
        return top...(top + max(0, view.visibleHeight))
    }

    private func distance(ofRowAt index: Int?, from screen: ClosedRange<CGFloat>) -> CGFloat {
        guard let index, let frame = layout.frame(at: index) else {
            return .infinity
        }
        return Self.distance(of: frame, from: screen)
    }

    /// How far a row is from what shows, nothing when any of it shows.
    private static func distance(of frame: CGRect, from screen: ClosedRange<CGFloat>) -> CGFloat {
        max(0, screen.lowerBound - frame.maxY, frame.minY - screen.upperBound)
    }

    /// The first row the person sees, and how far down the screen it starts.
    private func readingAnchor(in view: ThreadCollectionView) -> (row: ThreadRow.ID, top: CGFloat)? {
        let visibleTop = view.contentOffset.y + view.adjustedContentInset.top
        for index in view.indexPathsForVisibleItems.map(\.item).sorted() where order.indices.contains(index) {
            if let frame = layout.frame(at: index), frame.maxY > visibleTop {
                return (order[index], frame.minY - view.contentOffset.y)
            }
        }
        return nil
    }

    /// The top of the first message among `arrived` that joined the bottom from someone
    /// else, when it is too tall to show whole at the newest: standing there, its top is
    /// above what shows. A page read in above is no arrival at the bottom.
    private func topOfTallArrival(among arrived: Set<ThreadRow.ID>, in view: ThreadCollectionView) -> CGFloat? {
        guard !arrived.isEmpty, let lastStaying = order.lastIndex(where: { !arrived.contains($0) }) else {
            return nil
        }
        let visibleTop = view.contentOffset.y + view.adjustedContentInset.top
        for index in order.indices.suffix(from: lastStaying + 1) {
            guard let row = rows[order[index]], case .message = row.content, !Self.isSending(row), let frame = layout.frame(at: index) else {
                continue
            }
            return frame.minY < visibleTop ? frame.minY : nil
        }
        return nil
    }

    private func restore(_ anchor: (row: ThreadRow.ID, top: CGFloat), in view: ThreadCollectionView) {
        guard let index = order.firstIndex(of: anchor.row), let frame = layout.frame(at: index) else {
            return
        }
        let offset = frame.minY - anchor.top
        if abs(view.contentOffset.y - offset) > 0.5 {
            view.contentOffset.y = offset
        }
    }

    // MARK: - UICollectionViewDelegate

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? ThreadCollectionCell)?.isDisplaying = true
        guard order.indices.contains(indexPath.item), let row = rows[order[indexPath.item]] else {
            return
        }
        ChatTiming.appeared(row, isNewest: indexPath.item == order.count - 1)
        cell.alpha = 1
        cell.transform = .identity
        if arriving.remove(row.id) != nil, !(look?.reducesMotion ?? false) {
            if Self.isSending(row) {
                // Grows out of its bottom trailing corner, so its bottom edge never moves.
                let scale: CGFloat = 0.9
                let size = cell.bounds.size
                cell.transform = CGAffineTransform(translationX: size.width * (1 - scale) / 2, y: size.height * (1 - scale) / 2)
                    .scaledBy(x: scale, y: scale)
                cell.alpha = 0.4
                UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.84, initialSpringVelocity: 0) {
                    cell.transform = .identity
                    cell.alpha = 1
                }
            } else {
                cell.alpha = 0
                UIView.animate(withDuration: 0.25) {
                    cell.alpha = 1
                }
            }
        }
        if case .older = row.content, hasRevealed, !isReadingOlder {
            isReadingOlder = true
            Task { [weak self] in
                await self?.list.loadOlder()
                self?.isReadingOlder = false
            }
        }
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? ThreadCollectionCell)?.isDisplaying = false
        if let row = (cell as? ThreadCollectionCell)?.host?.row {
            leftScreen.insert(row.id)
        }
    }

    /// Whether the row is a message this phone is sending, which rises rather than fades.
    private static func isSending(_ row: ThreadRow) -> Bool {
        if case .message(let content) = row.content {
            return content.message.status == .sending || content.message.status == .waiting
        }
        return false
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard let view = scrollView as? ThreadCollectionView else {
            return
        }
        if !view.isGliding, view.isTracking || view.isDecelerating {
            view.notePersonScrolled()
        }
        noteStanding(of: view)
    }

    /// Whether the list stands far enough above its newest row to offer the way back, after
    /// a scroll or after rows arrived below the person reading.
    private func noteStanding(of view: ThreadCollectionView) {
        let isFar = list.returnToLatest != nil || view.distanceFromNewest > view.visibleHeight / 2
        if isFarFromNewest != isFar {
            isFarFromNewest = isFar
            view.showJump(isFar, reducesMotion: look?.reducesMotion ?? false)
        }
    }

    /// Tapping the status bar goes to the oldest row read so far, and lets go of the newest.
    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        (scrollView as? ThreadCollectionView)?.letGo()
        return true
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        (scrollView as? ThreadCollectionView)?.notePersonScrolled()
        #if DEBUG
        ThreadFlingLog.shared.began()
        #endif
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            (scrollView as? ThreadCollectionView)?.notePersonScrolled()
            #if DEBUG
            ThreadFlingLog.shared.ended()
            #endif
            buildAhead()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        #if DEBUG
        ThreadFlingLog.shared.ended()
        #endif
        // A fling stopped by the jump to the newest ends here too, after the glide began,
        // and is no scroll of the person's that lets go of the newest.
        guard let view = scrollView as? ThreadCollectionView, !view.isGliding else {
            return
        }
        view.notePersonScrolled()
        buildAhead()
    }

    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        (scrollView as? ThreadCollectionView)?.notePersonScrolled()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        (scrollView as? ThreadCollectionView)?.endGlide()
        buildAhead()
    }
}

/// One row as its cell hosts it. Only the row the person is swiping reads how far its
/// timestamp is out, so the other cells are not redrawn while the finger moves.
private struct ThreadCell: View {
    let row: ThreadRow
    let conversation: RoomConversation
    let actions: ThreadActions
    let state: ThreadListState

    var body: some View {
        let isSwiped = state.revealedRow == row.id
        ThreadRowView(row: row, conversation: conversation, actions: actions,
                      timestampReveal: isSwiped ? state.timestampReveal : 0,
                      showsTimestamps: isSwiped && state.showsTimestamps)
            .equatable()
    }
}

