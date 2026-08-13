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
