// Padlink/PadlinkMac/ConnectionWatchdog.swift
import Foundation
import PadlinkCore

/// Notices an iPad that stopped talking.
///
/// The iPad sends `ping` every `Padlink.heartbeatInterval`, so on this side
/// silence is the signal. Anything inbound counts as proof of life, not only a
/// ping: during a drag the iPad is sending pointer moves constantly, and those
/// say just as much.
///
/// Why the Mac needs its own detection rather than trusting the socket: when
/// Wi-Fi drops there is no FIN, so `PadlinkConnection.incoming` never finishes,
/// so the read loop never ends, so nothing releases the mouse button the user
/// was dragging with. Darwin's TCP keepalive would eventually notice, but its
/// default probe interval and probe count put that closer to ten minutes. Ten
/// minutes of a stuck left button is not a recoverable state for the person
/// sitting at the Mac.
///
/// `tick()` is separate from the timer that calls it, so every rule here is
/// tested by driving ticks directly, with nothing sleeping and nothing timing
/// dependent.
@MainActor
final class ConnectionWatchdog {
    /// Counts intervals in which nothing arrived. `recordPingSent` reads
    /// oddly from this side: what it means here is that another ping's worth
    /// of time went by with nothing to show for it, which is exactly the
    /// "outstanding, unanswered" the monitor counts.
    private var monitor: HeartbeatMonitor
    private let interval: TimeInterval
    private let onSilence: @MainActor () -> Void
    /// Latched, so the connection is torn down once rather than on every
    /// later tick.
    private var reported = false
    private var isRunning = true

    // Read access is internal rather than private so tests can assert on the
    // Timer's `isValid` directly, which is the only way to observe from
    // outside that `deinit` invalidated it. The same reasoning, and the same
    // shape, as `AccessibilityStatus.timer`.
    private(set) var timer: Timer?

    init(
        interval: TimeInterval = Padlink.heartbeatInterval,
        missedLimit: Int = Padlink.heartbeatMissedLimit,
        onSilence: @escaping @MainActor () -> Void
    ) {
        self.interval = interval
        self.monitor = HeartbeatMonitor(missedLimit: missedLimit)
        self.onSilence = onSilence
    }

    var hasGivenUp: Bool { reported }

    /// The peer said something. Any frame at all.
    func noteFrameReceived() {
        guard isRunning else { return }
        monitor.recordPongReceived()
    }

    /// One interval elapsed.
    func tick() {
        guard isRunning, reported == false else { return }
        monitor.recordPingSent()
        guard monitor.isDead else { return }
        reported = true
        stop()
        onSilence()
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// Stops the timer and makes every later `tick()` inert.
    ///
    /// Both halves matter. A watchdog belonging to a superseded connection
    /// must not report silence for a socket nobody is using, and a `tick()`
    /// already queued on the run loop can still land after `invalidate()`.
    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
    }

    isolated deinit {
        timer?.invalidate()
        timer = nil
    }
}
