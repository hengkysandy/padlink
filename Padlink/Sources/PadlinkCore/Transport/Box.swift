import Foundation

/// A lock-backed mutable reference.
///
/// Network.framework's callback closures (`stateUpdateHandler`, `receive`
/// completion, `send` completion) are `@Sendable`, so Swift 6 strict
/// concurrency rejects mutating a plain captured `var` from inside them. This
/// box gives those closures a safe place to write things like "have I already
/// resumed this continuation", or to retain state such as accepted
/// connections, which ARC would otherwise free mid-handshake.
///
/// Not `public`: this is an implementation detail of PadlinkCore's
/// Network.framework integration, not part of the package's API. Test
/// targets reach it through `@testable import`.
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T

    init(_ value: T) {
        storage = value
    }

    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); defer { lock.unlock() }; storage = newValue }
    }
}

extension Box where T == Bool {
    /// Atomically tests and sets the value to `true` under a single lock
    /// acquisition, returning `true` only to the first caller.
    ///
    /// Replaces the copied "guard !resumed.value else return; resumed.value =
    /// true" pattern, which takes the lock twice and leaves a gap between the
    /// read and the write. Most call sites only get away with that because
    /// Network.framework serialises its callbacks on one queue. Where two
    /// independent tasks can race (a completion firing at the same moment as
    /// a timeout), the gap is a genuine race that can resume the same
    /// continuation twice, which is undefined behavior.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !storage else { return false }
        storage = true
        return true
    }
}
