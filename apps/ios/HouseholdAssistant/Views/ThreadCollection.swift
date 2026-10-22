// The thread's collection view in SwiftUI: the rows and actions from the room, and the part
// of the window the bars above and the composer and keyboard below leave uncovered, which
// the list scrolls under and keeps its newest row inside, moving with the keyboard as it
// rises and falls.

import SwiftUI
import UIKit

struct ThreadPreparation {
    let isReady: ([RoomMessage]) -> Bool
    let prepare: ([RoomMessage]) async -> Void
}

struct ThreadCollection: UIViewRepresentable {
    let conversation: RoomConversation
    let rows: [ThreadRow]
    /// The newest message's bubble when this phone wrote it, which the list glides to.
    let newestOwnBubble: String?
    let actions: ThreadActions
    let loadOlder: () async -> Void
    /// The part of the window no bar, composer or keyboard covers.
    let uncovered: CGRect
    let state: ThreadListState
    /// The message to bring into view, as a search result picked asks.
    let jump: ThreadJump?
    var preparation: ThreadPreparation? = nil
    var returnToLatest: (() -> Void)? = nil

    func makeCoordinator() -> ThreadCollectionCoordinator {
        ThreadCollectionCoordinator(list: self)
    }

    func makeUIView(context: Context) -> ThreadCollectionView {
        let view = ThreadCollectionView(frame: .zero, collectionViewLayout: context.coordinator.layout)
        view.backgroundColor = .clear
        view.contentInsetAdjustmentBehavior = .never
        view.keyboardDismissMode = .interactive
        view.alwaysBounceVertical = true
        // How the UI tests find the thread.
        view.accessibilityIdentifier = "room.thread"
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ view: ThreadCollectionView, context: Context) {
        if uncovered != view.uncovered {
            view.uncovered = uncovered
            // With the keyboard's own animation, so the rows rise and fall with the composer.
            context.animate {
                view.keepClearOfCovered()
            }
        }
        context.coordinator.update(self, environment: context.environment)
    }

    static func dismantleUIView(_ view: ThreadCollectionView, coordinator: ThreadCollectionCoordinator) {
        coordinator.letGoOfAllRows()
    }
}

