// Padlink/PadlinkPadTests/LatencyTrackerTests.swift
import XCTest
@testable import PadlinkPad

/// The round trip figure. Timestamps are arguments rather than clock reads, so
/// every rule here is testable with no timers and no network.
final class LatencyTrackerTests: XCTestCase {

    func testNoFigureBeforeTheFirstPong() {
        var tracker = LatencyTracker()
        tracker.recordPing(seq: 1, at: 100)
        XCTAssertNil(tracker.milliseconds)
    }

    func testAPongGivesTheRoundTripInMilliseconds() {
        var tracker = LatencyTracker()
        tracker.recordPing(seq: 1, at: 100)
        tracker.recordPong(seq: 1, at: 100.024)
        XCTAssertEqual(tracker.milliseconds, 24)
    }

    /// A pong that matches no outstanding ping is a stray frame, and taking it
    /// as a measurement would invent a figure out of an unrelated timestamp.
    func testAPongForAnUnknownPingChangesNothing() {
        var tracker = LatencyTracker()
        tracker.recordPing(seq: 1, at: 100)
        tracker.recordPong(seq: 99, at: 100.5)
        XCTAssertNil(tracker.milliseconds)
    }

    /// A pong proves every earlier ping is never coming back. Keeping them
    /// would let a long-dead ping match a much later pong whose sequence number
    /// wrapped around to the same value, and report a round trip of minutes.
    func testAnsweringAPingDropsEveryOlderOne() {
        var tracker = LatencyTracker()
        tracker.recordPing(seq: 1, at: 100)
        tracker.recordPing(seq: 2, at: 103)
        tracker.recordPong(seq: 2, at: 103.03)
        XCTAssertEqual(tracker.milliseconds, 30)

        // Ping 1 is gone, so its late answer measures nothing.
        tracker.recordPong(seq: 1, at: 200)
        XCTAssertEqual(tracker.milliseconds, 30)
    }

    /// Smoothed, because a single sample jitters by tens of milliseconds on
    /// Wi-Fi and a figure that changes every tick is one nobody can read. The
    /// second sample must move it without replacing it.
    func testTheFigureIsSmoothedRatherThanReplaced() throws {
        var tracker = LatencyTracker()
        tracker.recordPing(seq: 1, at: 100)
        tracker.recordPong(seq: 1, at: 100.020)
        XCTAssertEqual(tracker.milliseconds, 20)

        tracker.recordPing(seq: 2, at: 103)
        tracker.recordPong(seq: 2, at: 103.120)

        // Between the two, and past the midpoint of 70, which is what
        // "weighted toward the newest" has to mean to be worth saying.
        let figure = try XCTUnwrap(tracker.milliseconds)
        XCTAssertGreaterThan(figure, 70)
        XCTAssertLessThan(figure, 120)
    }

    /// A link that genuinely gets worse has to become visible within a couple
    /// of pings. Smoothing so heavy that it takes a minute to react would hide
    /// exactly the thing the figure exists to show.
    func testAWorseLinkShowsUpWithinAFewPings() {
        var tracker = LatencyTracker()
        tracker.recordPing(seq: 1, at: 100)
        tracker.recordPong(seq: 1, at: 100.020)

        for seq in UInt32(2)...4 {
            let sent = 100 + Double(seq) * 3
            tracker.recordPing(seq: seq, at: sent)
            tracker.recordPong(seq: seq, at: sent + 0.200)
        }
        XCTAssertGreaterThan(try XCTUnwrap(tracker.milliseconds), 150)
    }

    /// A negative sample means the clock moved under us rather than the network
    /// being strange, and showing it would be worse than showing the last good
    /// figure.
    func testAnImpossibleSampleIsIgnored() {
        var tracker = LatencyTracker()
        tracker.recordPing(seq: 1, at: 100)
        tracker.recordPong(seq: 1, at: 100.020)

        tracker.recordPing(seq: 2, at: 103)
        tracker.recordPong(seq: 2, at: 102)
        XCTAssertEqual(tracker.milliseconds, 20)
    }

    func testAnAbsurdlyLargeSampleIsIgnored() {
        var tracker = LatencyTracker()
        tracker.recordPing(seq: 1, at: 100)
        tracker.recordPong(seq: 1, at: 100.020)

        tracker.recordPing(seq: 2, at: 103)
        tracker.recordPong(seq: 2, at: 903)
        XCTAssertEqual(tracker.milliseconds, 20)
    }

    /// A new connection starts with no history. Carrying a figure across shows
    /// the old link's latency for the new one's first few seconds, which is
    /// exactly when somebody who just reconnected is looking at it.
    func testResetClearsTheFigure() {
        var tracker = LatencyTracker()
        tracker.recordPing(seq: 1, at: 100)
        tracker.recordPong(seq: 1, at: 100.020)
        tracker.reset()
        XCTAssertNil(tracker.milliseconds)
    }

    /// Unanswered pings are dropped too, or a pong from the old connection
    /// could match a ping the new one never sent.
    func testResetDropsOutstandingPings() {
        var tracker = LatencyTracker()
        tracker.recordPing(seq: 1, at: 100)
        tracker.reset()
        tracker.recordPong(seq: 1, at: 100.020)
        XCTAssertNil(tracker.milliseconds)
    }

    /// The heartbeat pings for as long as the app runs. Remembering every one
    /// would grow without limit on a link that stays up for hours.
    func testOutstandingPingsAreBounded() {
        var tracker = LatencyTracker()
        for seq in UInt32(1)...500 {
            tracker.recordPing(seq: seq, at: Double(seq))
        }
        // The oldest are gone, so their answers measure nothing.
        tracker.recordPong(seq: 1, at: 1.01)
        XCTAssertNil(tracker.milliseconds)
        // The newest still work.
        tracker.recordPong(seq: 500, at: 500.05)
        XCTAssertEqual(tracker.milliseconds, 50)
    }
}
