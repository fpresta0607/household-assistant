// One piece of an assistant's message, in the order it was written.

import Foundation

enum MessageSegment: Equatable, Sendable {
    case markdown(String)
    case card(StewardCard)
    /// A card whose block is still arriving. Shown as a quiet placeholder, never as JSON.
    case pendingCard
    /// A block that is not a card this app can draw, shown as the text it is.
    case code(String)
}
