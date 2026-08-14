// Padlink/PadlinkPad/LatencyTracker.swift
import Foundation

/// How long a message takes to reach the Mac and come back.
///
/// This is the number the whole product rests on and the one nobody had. The
/// design estimated 20 to 40 milliseconds and nothing ever checked. Showing it
/// costs one subtraction, because the heartbeat already sends a ping with a
/// sequence number and already gets a pong back.
///
/// What it buys, beyond the number itself, is the ability to tell two failures
/// apart. A trackpad that feels bad because the Wi-Fi is congested and a
/// trackpad that feels bad because the app is doing something wrong look
/// identical from the outside. One of them shows 180ms.
///
/// # Why it lives outside the state machine
///
/// `PadStateMachine` is deliberately clockless: every rule in it is testable
/// with no timers because nothing in it can ask what time it is. Latency is
/// nothing but a question about time, so putting it there would put a clock in
/// the one type built to avoid one. It sits in `PadService` instead, which owns
/// the I/O and the timing already, and it takes its timestamps as arguments so
/// it is still testable with no clock at all.
struct LatencyTracker: Equatable {
    /// Pings sent and not yet answered, oldest first.
    private var outstanding: [(seq: UInt32, sentAt: TimeInterval)] = []

    /// The smoothed round trip, in milliseconds, or nil before the first pong.
    private(set) var milliseconds: Int?

    /// How many unanswered pings to remember.
    ///
    /// Small on purpose. The heartbeat pings every few seconds and gives up
    /// after a handful of misses, so anything older than this is from a link
    /// that is already being declared dead.
    private static let maxOutstanding = 8

    init() {}

    static func == (lhs: LatencyTracker, rhs: LatencyTracker) -> Bool {
        lhs.milliseconds == rhs.milliseconds
            && lhs.outstanding.map(\.seq) == rhs.outstanding.map(\.seq)
    }

    mutating func recordPing(seq: UInt32, at timestamp: TimeInterval) {
        outstanding.append((seq, timestamp))
        if outstanding.count > Self.maxOutstanding {
            outstanding.removeFirst(outstanding.count - Self.maxOutstanding)
        }
    }

    /// Matches a pong to its ping and updates the figure.
    ///
    /// Everything older than the answered ping is dropped. A pong proves every
    /// earlier ping is never coming back, and keeping them would let a
    /// long-dead ping match a much later pong whose sequence number wrapped
    /// around to the same value.
    mutating func recordPong(seq: UInt32, at timestamp: TimeInterval) {
        guard let index = outstanding.firstIndex(where: { $0.seq == seq }) else { return }
        let sample = (timestamp - outstanding[index].sentAt) * 1000
        outstanding.removeFirst(index + 1)

        // A negative or absurd sample means the clock moved under us rather
        // than the network being strange, and showing it would be worse than
        // showing the previous value.
        guard sample >= 0, sample < 10_000 else { return }

        // Smoothed, because a single sample jitters by tens of milliseconds on
        // Wi-Fi and a number that changes every tick is one nobody can read.
        //
        // Weighted toward the newest sample, not away from it. The heartbeat
        // only pings every few seconds, so there are very few samples to work
        // with, and leaning on the history would mean a link that genuinely got
        // worse took most of a minute to admit it. That is the one moment the
        // figure exists for.
        if let current = milliseconds {
            milliseconds = Int((Double(current) * 0.4 + sample * 0.6).rounded())
        } else {
            milliseconds = Int(sample.rounded())
        }
    }

    /// A new connection starts with no history. Carrying a figure across would
    /// show the old link's latency for the new one's first few seconds.
    mutating func reset() {
        outstanding.removeAll()
        milliseconds = nil
    }
}
