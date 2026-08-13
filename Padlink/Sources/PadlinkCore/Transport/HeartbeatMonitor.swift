import Foundation

/// Counts unanswered pings. Without this, a dead connection sits unnoticed
/// until TCP gives up, which can take over a minute.
public struct HeartbeatMonitor: Sendable {
    public let missedLimit: Int
    public private(set) var missedCount = 0

    public init(missedLimit: Int = 3) {
        self.missedLimit = missedLimit
    }

    public mutating func recordPingSent() {
        missedCount += 1
    }

    public mutating func recordPongReceived() {
        missedCount = 0
    }

    public var isDead: Bool {
        missedCount >= missedLimit
    }
}
