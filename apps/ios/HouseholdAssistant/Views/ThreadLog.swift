// How the thread's list moved, in the system log of a debug build: each update, each row
// measured and each pin, by place and identity, never a word of any message. A UI test that
// launches with `-StewardThreadLog YES` can also read the newest lines on screen
// (ThreadLogElement), since the simulator it ran on is gone before its log can be read.
// A release build says nothing.

import Foundation
import Observation
import os

@MainActor
enum ThreadLog {
    #if DEBUG
    private static let logger = Logger(subsystem: "com.siqstack.stewardai", category: "thread")

    /// Whether a UI test asked to read the lines on screen.
    static let isShown = UserDefaults.standard.bool(forKey: "StewardThreadLog")

    /// The newest lines, for ThreadLogElement.
    @Observable
    final class Lines {
        static let shared = Lines()
        private(set) var newest: [String] = []

        func add(_ line: String) {
            newest.append(line)
            if newest.count > 40 {
                newest.removeFirst(newest.count - 40)
            }
        }
    }
    #endif

    static func note(_ message: @autoclosure () -> String) {
        #if DEBUG
        let text = message()
        logger.notice("\(text, privacy: .public)")
        if isShown {
            Lines.shared.add(text)
        }
        #endif
    }
}
