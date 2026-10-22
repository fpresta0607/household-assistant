// Which checklist item a tick is about: the assistant's message, the list's id in it, and
// the item's place in the list.

import Foundation

struct ChecklistTick: Hashable, Sendable {
    let messageId: String
    let cardId: String
    let item: Int
}
