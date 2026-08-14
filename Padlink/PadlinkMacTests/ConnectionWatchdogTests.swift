// Padlink/PadlinkMacTests/ConnectionWatchdogTests.swift
import XCTest
import PadlinkCore
@testable import PadlinkMac

/// The Mac's half of the heartbeat.
///
/// The iPad sends `ping` on a timer, so the Mac can treat any silence longer
/// than a few intervals as a dead peer. That matters more on this side than on
/// the iPad's: when Wi-Fi drops mid-drag the Mac is left holding a mouse button
/// down, and nothing releases it until the read loop ends, which without this
/// watchdog can take TCP the better part of ten minutes.
///
/// Every test here drives `tick()` by hand. Nothing sleeps, so nothing is
/// timing-dependent and the whole file runs in microseconds.
@MainActor
final class ConnectionWatchdogTests: XCTestCase {
    private var silenceReports = 0

    private func makeWatchdog(missedLimit: Int = Padlink.heartbeatMissedLimit) -> ConnectionWatchdog {
        ConnectionWatchdog(
            interval: 60,
            missedLimit: missedLimit,
            onSilence: { [self] in silenceReports += 1 }
        )
    }

    func testStartsAlive() {
        let watchdog = makeWatchdog()
        XCTAssertFalse(watchdog.hasGivenUp)
        XCTAssertEqual(silenceReports, 0)
    }

    /// The boundary that matters. One interval of quiet is normal: the iPad
    /// may simply not have sent its next ping yet.
    func testOneSilentIntervalIsNotEnoughToGiveUp() {
        let watchdog = makeWatchdog()
        watchdog.tick()
        XCTAssertFalse(watchdog.hasGivenUp)
        XCTAssertEqual(silenceReports, 0)
    }

    func testSilenceOneIntervalShortOfTheLimitStillHolds() {
        let watchdog = makeWatchdog(missedLimit: 3)
        watchdog.tick()
        watchdog.tick()
        XCTAssertFalse(watchdog.hasGivenUp)
        XCTAssertEqual(silenceReports, 0)
    }

    func testEnoughSilentIntervalsReportTheDeadPeer() {
        let watchdog = makeWatchdog(missedLimit: 3)
        watchdog.tick()
        watchdog.tick()
        watchdog.tick()
        XCTAssertTrue(watchdog.hasGivenUp)
        XCTAssertEqual(silenceReports, 1)
    }

    /// Any inbound frame counts, not only a ping. During an active drag the
    /// iPad is sending pointer moves constantly, and those are proof of life
    /// just as good as a ping.
    func testAnyInboundFrameResetsTheCount() {
        let watchdog = makeWatchdog(missedLimit: 3)
        watchdog.tick()
        watchdog.tick()
        watchdog.noteFrameReceived()
        watchdog.tick()
        watchdog.tick()
        XCTAssertFalse(watchdog.hasGivenUp)
        XCTAssertEqual(silenceReports, 0)
    }

    /// The callback tears down the connection. Firing it again on every later
    /// tick would tear down whatever replaced it.
    func testItReportsSilenceOnlyOnce() {
        let watchdog = makeWatchdog(missedLimit: 2)
        for _ in 0 ..< 10 { watchdog.tick() }
        XCTAssertEqual(silenceReports, 1)
    }

    /// A watchdog belonging to a superseded connection must go quiet, or it
    /// reports silence for a socket nobody is using any more.
    func testAStoppedWatchdogNeverReportsSilence() {
        let watchdog = makeWatchdog(missedLimit: 2)
        watchdog.stop()
        watchdog.tick()
        watchdog.tick()
        watchdog.tick()
        XCTAssertEqual(silenceReports, 0)
        XCTAssertFalse(watchdog.hasGivenUp)
    }

    // MARK: - The timer that drives it in production

    func testStartSchedulesATimerAndStopInvalidatesIt() {
        let watchdog = makeWatchdog()
        watchdog.start()
        let timer = watchdog.timer
        XCTAssertEqual(timer?.isValid, true)
        watchdog.stop()
        XCTAssertEqual(timer?.isValid, false)
        XCTAssertNil(watchdog.timer)
    }

    func testStartingTwiceDoesNotCreateASecondTimer() {
        let watchdog = makeWatchdog()
        watchdog.start()
        let first = watchdog.timer
        watchdog.start()
        XCTAssertTrue(first === watchdog.timer)
        watchdog.stop()
    }

    /// The same orphaned-timer leak `AccessibilityStatus` already guards
    /// against: a watchdog dropped while running would leave a timer firing on
    /// the run loop for the life of the process.
    func testDeinitInvalidatesTheTimer() {
        var watchdog: ConnectionWatchdog? = makeWatchdog()
        watchdog?.start()
        let timer = watchdog?.timer
        XCTAssertEqual(timer?.isValid, true)

        watchdog = nil

        XCTAssertEqual(timer?.isValid, false, "deinit should invalidate the watchdog timer")
    }
}
