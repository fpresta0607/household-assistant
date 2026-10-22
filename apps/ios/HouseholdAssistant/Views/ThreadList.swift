// A conversation's rows, laid out the way Messages, Signal and Telegram lay out theirs: a
// collection view whose rows keep the height they drew at (ThreadLayout), so only rows near
// the screen are built, opening and leaving cost the same in a thread of any length, and a
// row is drawn again only when what it shows changes (CFO notes section 21a). SwiftUI's lazy
// stack guessed the height of every row it had not built from the rows it had, so a thread
// of short answers and long devotionals moved under the reader as it corrected its guesses,
// and kept the newest row clear of the composer only a pass after each change.
//
// The list stands at its newest row until the person scrolls up to read. While it stands
// there, whatever joins the bottom or grows there keeps the newest row just above the
// composer, through the keyboard rising and falling too (ThreadCollectionView). Scrolled up,
// nothing the person reads moves, and a control to jump back to the newest shows (section
// 21b). Swiping left drags every row's time out from its side. The room supplies the rows
// and what they do.

import SwiftUI

struct ThreadList: View {
    let conversation: RoomConversation
    let rows: [ThreadRow]
    /// The newest message's bubble when this phone wrote it, which the list glides to.
    let newestOwnBubble: String?
    let actions: ThreadActions
    let loadOlder: () async -> Void
    /// What the rows share, which the room's lifted message shares too.
    let state: ThreadListState
    /// The message to bring into view, as a search result picked asks.
    var jump: ThreadJump? = nil
    var preparation: ThreadPreparation? = nil
    var returnToLatest: (() -> Void)? = nil

    @Environment(\.reducesMotion) private var reducesMotion
    /// The part of the window no bar, composer or keyboard covers.
    @State private var uncovered = CGRect.zero
    @State private var timestampReturn: Task<Void, Never>?
    @ScaledMetric(relativeTo: .caption) private var timestampWidth: CGFloat = 80

    var body: some View {
        ZStack {
            // Laid out in the safe area, which is what the bars, the composer and the keyboard
            // leave, and measured on screen, where the list compares it with itself.
            Color.clear
                .onGeometryChange(for: CGRect.self) { geometry in
                    geometry.frame(in: .global)
                } action: { frame in
                    uncovered = frame
                }
            ThreadCollection(
                conversation: conversation,
                rows: rows,
                newestOwnBubble: newestOwnBubble,
                actions: actions,
                loadOlder: loadOlder,
                uncovered: uncovered,
                state: state,
                jump: jump,
                preparation: preparation,
                returnToLatest: returnToLatest
            )
            // Under the bars and the composer, which it scrolls under and keeps its rows clear
            // of at rest.
            .ignoresSafeArea()
            #if DEBUG
            if ThreadLog.isShown {
                ThreadLogElement()
            }
            #endif
        }
        .gesture(ThreadTimestampGesture(
            onBegin: { point in
                // The swipe reveals the timestamp of the message it began on, and no other.
                timestampReturn?.cancel()
                timestampReturn = nil
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    state.timestampReveal = 0
                    state.showsTimestamps = false
                    state.revealedRow = state.rowAt(point)
                }
            },
            onChange: { distance in
                guard state.revealedRow != nil else { return }
                timestampReturn?.cancel()
                timestampReturn = nil
                // Follow the finger directly, including when a second swipe interrupts
                // the return. Only letting go animates; dragging never springs.
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    state.showsTimestamps = distance > 0
                    state.timestampReveal = min(distance, timestampWidth)
                }
                #if DEBUG
                DemoTimestampObservation.shared.held(state.timestampReveal > 0)
                #endif
            },
            onEnd: {
                timestampReturn?.cancel()
                #if DEBUG
                ThreadLog.note("timestamps released at \(state.timestampReveal)")
                DemoTimestampObservation.shared.held(false)
                #endif
                withAnimation(reducesMotion ? nil : .easeOut(duration: 0.18)) {
                    state.timestampReveal = 0
                }
                // Rows have separate hosting controllers. Retain their labels until
                // the return finishes, then remove them from both drawing and accessibility.
                // A new drag cancels this cleanup before it can hide the new timestamps.
                if reducesMotion {
                    state.showsTimestamps = false
                    state.revealedRow = nil
                } else {
                    timestampReturn = Task { @MainActor in
                        do { try await Task.sleep(for: .milliseconds(200)) }
                        catch { return }
                        state.showsTimestamps = false
                        state.revealedRow = nil
                        timestampReturn = nil
                    }
                }
            }
        ))
        .onDisappear {
            timestampReturn?.cancel()
            timestampReturn = nil
            state.timestampReveal = 0
            state.showsTimestamps = false
            state.revealedRow = nil
        }
    }
}

