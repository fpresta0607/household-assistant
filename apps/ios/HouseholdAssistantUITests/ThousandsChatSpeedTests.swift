// Every timing in ChatSpeedTests again, on a thread of thousands of messages: Corey's four
// days laid down 70 times over, about 3,000 messages and 350 long devotionals, all of it on
// the phone as it is once the owner has read back through it (CFO notes section 21a).

import XCTest

final class ThousandsChatSpeedTests: ChatSpeedTests {
    override class var repeats: Int {
        70
    }
}
