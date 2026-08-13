// Padlink/PadlinkPadTests/MoveThrottleTests.swift
import XCTest
import PadlinkCore
@testable import PadlinkPad

final class MoveThrottleTests: XCTestCase {

    // MARK: - The gap, which is the crash

    /// The reason this type exists. `dtMicros` is `UInt16`, so it stops at
    /// 65535 microseconds, about 65 milliseconds. A finger that pauses for a
    /// few seconds and then moves produces a far larger gap, and a plain
    /// `UInt16(gap)` conversion traps, which on iOS means the app vanishes.
    func testGapFarBeyondUInt16MaxClampsInsteadOfCrashing() {
        var throttle = MoveThrottle()
        throttle.begin(at: 100.0)
        // Five seconds is 5,000,000 microseconds, about 76 times UInt16.max.
        let message = throttle.move(dx: 10, dy: 0, at: 105.0)
        XCTAssertEqual(message, .pointerMove(dx: 10, dy: 0, dtMicros: 65535))
    }

    /// Two touches in the same event batch share a timestamp, so the gap is
    /// zero. Zero is a legal `UInt16` but a useless divisor for the Mac's
    /// speed calculation, so the floor is 1, not 0.
    func testZeroGapClampsToOne() {
        var throttle = MoveThrottle()
        throttle.begin(at: 100.0)
        XCTAssertEqual(throttle.move(dx: 3, dy: 0, at: 100.0),
                       .pointerMove(dx: 3, dy: 0, dtMicros: 1))
    }

    /// A negative gap should never happen, but a negative Double converted to
    /// `UInt16` traps just as hard as an oversized one.
    func testBackwardsTimestampClampsToOne() {
        var throttle = MoveThrottle()
        throttle.begin(at: 100.0)
        XCTAssertEqual(throttle.move(dx: 3, dy: 0, at: 99.5),
                       .pointerMove(dx: 3, dy: 0, dtMicros: 1))
    }

    /// The ordinary case: a 120 Hz touch stream is about 8 ms per event.
    func testNormalGapBecomesMicroseconds() {
        var throttle = MoveThrottle()
        throttle.begin(at: 100.0)
        XCTAssertEqual(throttle.move(dx: 4, dy: -2, at: 100.008),
                       .pointerMove(dx: 4, dy: -2, dtMicros: 8000))
    }

    /// A gap of exactly `UInt16.max` microseconds is the last legal value and
    /// must survive unchanged. Pins the clamp to 65535 rather than 65534.
    func testGapAtExactlyUInt16MaxIsUnchanged() {
        var throttle = MoveThrottle()
        throttle.begin(at: 100.0)
        XCTAssertEqual(throttle.move(dx: 1, dy: 0, at: 100.065535),
                       .pointerMove(dx: 1, dy: 0, dtMicros: 65535))
    }

    // MARK: - The delta

    /// `Int16` conversion traps the same way `UInt16` does.
    func testDeltaBeyondInt16MaxIsClamped() {
        var throttle = MoveThrottle()
        throttle.begin(at: 100.0)
        XCTAssertEqual(throttle.move(dx: 100_000, dy: -100_000, at: 100.008),
                       .pointerMove(dx: 32767, dy: -32768, dtMicros: 8000))
    }

    /// Clamping throws the excess away rather than carrying it. Carrying it
    /// would make one absurd delta turn into a cursor that keeps sliding for
    /// several more events with no finger movement behind it.
    func testClampedExcessDoesNotCarryIntoTheNextMove() {
        var throttle = MoveThrottle()
        throttle.begin(at: 100.0)
        _ = throttle.move(dx: 100_000, dy: 0, at: 100.008)
        XCTAssertEqual(throttle.move(dx: 2, dy: 0, at: 100.016),
                       .pointerMove(dx: 2, dy: 0, dtMicros: 8000))
    }

    /// A delta that is not a number cannot be converted to `Int16` either.
    /// Same crash class as the gap, so it gets the same treatment.
    func testNonFiniteDeltaIsIgnoredRatherThanTrapping() {
        var throttle = MoveThrottle()
        throttle.begin(at: 100.0)
        XCTAssertNil(throttle.move(dx: .nan, dy: .infinity, at: 100.008))
        // And the throttle still works afterwards.
        XCTAssertEqual(throttle.move(dx: 5, dy: 0, at: 100.016),
                       .pointerMove(dx: 5, dy: 0, dtMicros: 16000))
    }

    // MARK: - Not spamming the socket

    func testZeroMoveReturnsNil() {
        var throttle = MoveThrottle()
        throttle.begin(at: 100.0)
        XCTAssertNil(throttle.move(dx: 0, dy: 0, at: 100.008))
    }

    func testSubPixelMoveReturnsNil() {
        var throttle = MoveThrottle()
        throttle.begin(at: 100.0)
        XCTAssertNil(throttle.move(dx: 0.4, dy: -0.3, at: 100.008))
    }

    /// One axis moving is enough. An earlier draft that required both to be
    /// non-zero would drop every straight horizontal drag.
    func testMoveOnOneAxisOnlyStillEmits() {
        var throttle = MoveThrottle()
        throttle.begin(at: 100.0)
        XCTAssertEqual(throttle.move(dx: 0, dy: 3, at: 100.008),
                       .pointerMove(dx: 0, dy: 3, dtMicros: 8000))
    }

    // MARK: - Sub-pixel accumulation

    /// A slow drag delivers less than a point per event. Discarding those
    /// would make the cursor refuse to move at all below some speed.
    func testAccumulationCrossesTheOnePointBoundary() {
        var throttle = MoveThrottle()
        throttle.begin(at: 100.0)
        XCTAssertNil(throttle.move(dx: 0.4, dy: 0, at: 100.008))
        XCTAssertNil(throttle.move(dx: 0.4, dy: 0, at: 100.016))
        // 0.4 + 0.4 + 0.4 = 1.2, so this one crosses.
        let third = throttle.move(dx: 0.4, dy: 0, at: 100.024)
        guard case let .pointerMove(dx, _, _) = try? XCTUnwrap(third) else {
            return XCTFail("expected a pointerMove, got \(String(describing: third))")
        }
        XCTAssertEqual(dx, 1)
    }

    /// The gap on an accumulated move must span every event that fed it. The
    /// Mac divides distance by time to get speed for its acceleration curve,
    /// so reporting three events of distance against one event of time would
    /// tell it the finger was moving three times faster than it was.
    func testAccumulatedMoveReportsTimeSinceTheLastSentMove() {
        var throttle = MoveThrottle()
        throttle.begin(at: 100.0)
        _ = throttle.move(dx: 0.4, dy: 0, at: 100.008)
        _ = throttle.move(dx: 0.4, dy: 0, at: 100.016)
        XCTAssertEqual(throttle.move(dx: 0.4, dy: 0, at: 100.024),
                       .pointerMove(dx: 1, dy: 0, dtMicros: 24000))
    }

    /// The leftover after an emitted move is kept, so a steady 1.6 per event
    /// alternates 1, 2, 1, 2 rather than losing 0.6 every time.
    func testRemainderCarriesAfterAnEmittedMove() {
        var throttle = MoveThrottle()
        throttle.begin(at: 100.0)
        XCTAssertEqual(throttle.move(dx: 1.6, dy: 0, at: 100.008),
                       .pointerMove(dx: 1, dy: 0, dtMicros: 8000))
        // 0.6 left over, plus 1.6, is 2.2.
        XCTAssertEqual(throttle.move(dx: 1.6, dy: 0, at: 100.016),
                       .pointerMove(dx: 2, dy: 0, dtMicros: 8000))
    }

    /// Same accumulation, in the negative direction. Truncation toward zero
    /// is symmetric; truncation via `floor` would not be.
    func testAccumulationWorksInTheNegativeDirection() {
        var throttle = MoveThrottle()
        throttle.begin(at: 100.0)
        XCTAssertNil(throttle.move(dx: -0.4, dy: 0, at: 100.008))
        XCTAssertNil(throttle.move(dx: -0.4, dy: 0, at: 100.016))
        XCTAssertEqual(throttle.move(dx: -0.4, dy: 0, at: 100.024),
                       .pointerMove(dx: -1, dy: 0, dtMicros: 24000))
    }

    // MARK: - Drag boundaries

    /// A new drag starts fresh. Without this, the remainder and the elapsed
    /// time from the end of the last drag leak into the first move of the
    /// next one, which on a paused finger is exactly the oversized gap this
    /// type exists to prevent.
    func testBeginClearsStateFromThePreviousDrag() {
        var throttle = MoveThrottle()
        throttle.begin(at: 100.0)
        _ = throttle.move(dx: 0.9, dy: 0.9, at: 100.008)

        throttle.begin(at: 200.0)
        XCTAssertNil(throttle.move(dx: 0.4, dy: 0.4, at: 200.008))
    }

    /// A move with no `begin` before it has no previous timestamp to measure
    /// from. It must still not crash, and it must not invent a huge gap out
    /// of the absolute timestamp value.
    func testMoveWithoutBeginUsesTheFloorGap() {
        var throttle = MoveThrottle()
        XCTAssertEqual(throttle.move(dx: 3, dy: 0, at: 100_000.0),
                       .pointerMove(dx: 3, dy: 0, dtMicros: 1))
    }
}
