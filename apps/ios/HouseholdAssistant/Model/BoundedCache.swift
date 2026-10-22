// What was worked out once from a message, kept so the next time it is asked for it is
// read rather than worked out again: at most `capacity` values, and when it is full the
// one used longest ago gives way to the new one.
//
// The thread asks for the same message many times each time anything in it changes, from
// views on the main thread and from tests on theirs, so the cache takes a lock rather than
// an actor. The work itself runs outside the lock: two callers asking for the same new
// key at once may both do it, and the second result is kept, which is harmless.

import Foundation

final class BoundedCache<Key: Hashable & Sendable, Value: Sendable>: @unchecked Sendable {
    private struct Entry {
        let value: Value
        var lastUse: UInt64
    }

    let capacity: Int
    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    /// Counts every read and write, so the entry read longest ago has the lowest mark.
    private var clock: UInt64 = 0

    init(capacity: Int) {
        self.capacity = capacity
    }

    var count: Int {
        lock.lock()
        defer {
            lock.unlock()
        }
        return entries.count
    }

    func value(for key: Key) -> Value? {
        lock.lock()
        defer {
            lock.unlock()
        }
        guard var entry = entries[key] else {
            return nil
        }
        clock += 1
        entry.lastUse = clock
        entries[key] = entry
        return entry.value
    }

    /// Keeps `value`, first forgetting the entry used longest ago when the cache is full.
    /// Finding it reads every entry, which is nothing beside the work a miss has just done.
    func insert(_ value: Value, for key: Key) {
        lock.lock()
        defer {
            lock.unlock()
        }
        clock += 1
        if entries[key] == nil, entries.count >= capacity,
           let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse })?.key {
            entries.removeValue(forKey: oldest)
        }
        entries[key] = Entry(value: value, lastUse: clock)
    }

    /// The value kept for `key`, or the one `make` works out, which is then kept.
    func value(for key: Key, orMake make: () -> Value) -> Value {
        if let kept = value(for: key) {
            return kept
        }
        let made = make()
        insert(made, for: key)
        return made
    }
}
