// What a row of a conversation's thread does when it is used, handed from the room
// (RoomView) through the thread's list (ThreadList) to each row (ThreadRowView): lifting a
// message for reactions, replying to it, opening its pictures, sending it again, and
// opening what was said in a call.

import Foundation

struct ThreadActions {
    /// Lifts a message for reactions from its bubble's frame on screen, with the menu
    /// beside where a finger pressed it, when one did.
    let onReact: (RoomMessage, CGRect, CGPoint?) -> Void
    let onReply: (RoomMessage) -> Void
    let onOpenMedia: (RoomMedia) -> Void
    let onRetry: (RoomMessage) -> Void
    let onOpenCall: (RoomMessage) -> Void
}
