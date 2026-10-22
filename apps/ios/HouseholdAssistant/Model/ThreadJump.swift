// A message the thread is asked to bring into view, as a search result picked does (CFO
// notes section 5). Each ask is counted, so asking for the same message again, after the
// person scrolled away from it, moves the thread to it again.

struct ThreadJump: Equatable, Sendable {
    let messageId: String
    let count: Int
}
