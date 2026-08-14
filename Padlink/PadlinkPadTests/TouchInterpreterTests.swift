// Padlink/PadlinkPadTests/TouchInterpreterTests.swift
import XCTest
import PadlinkCore
@testable import PadlinkPad

/// `TouchInterpreter` is the whole trackpad, minus UIKit. Everything the user
/// can feel is decided here, so everything the user can feel is tested here.
final class TouchInterpreterTests: XCTestCase {

    // MARK: - Helpers

    /// Builds one abstract touch event.
    ///
    /// `active` is every touch still on the glass **after** this event, which
    /// is the contract `TrackpadView` implements. An ending touch is therefore
    /// absent from the `.ended` event that reports it.
    private func event(
        _ phase: TouchPhase,
        _ active: [(Int, Double, Double)],
        at timestamp: TimeInterval
    ) -> TouchEvent {
        TouchEvent(
            phase: phase,
            active: active.map {
                TouchSample(id: TouchID($0.0), location: CGPoint(x: $0.1, y: $0.2))
            },
            timestamp: timestamp
        )
    }

    private let leftDown = ClientMessage.pointerButton(button: .left, isDown: true)
    private let leftUp = ClientMessage.pointerButton(button: .left, isDown: false)

    /// A finished tap, ending at `endedAt`. Used as the setup for every
    /// tap-then-drag test.
    @discardableResult
    private func tap(
        _ interpreter: TouchInterpreter,
        id: Int = 1,
        from startedAt: TimeInterval,
        to endedAt: TimeInterval
    ) -> [ClientMessage] {
        _ = interpreter.handle(event(.began, [(id, 0, 0)], at: startedAt))
        return interpreter.handle(event(.ended, [], at: endedAt))
    }

    // MARK: - One finger drag

    /// The success condition of the whole app: a finger moves, the cursor moves.
    func testOneFingerDragEmitsAPointerMove() {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, [(1, 0, 0)], at: 100))
        XCTAssertEqual(
            interpreter.handle(event(.moved, [(1, 10, 5)], at: 100.01)),
            [.pointerMove(dx: 10, dy: 5, dtMicros: 10_000)]
        )
    }

    /// Nothing may be sent on touch down. A plain tap is not known to be a tap
    /// until it ends, and a press that turns into a drag must not click first.
    func testTouchDownAloneSendsNothing() {
        let interpreter = TouchInterpreter()
        XCTAssertEqual(interpreter.handle(event(.began, [(1, 0, 0)], at: 100)), [])
    }

    /// Trap E. A finger resting still produces a stream of `.moved` events with
    /// no movement in them. Sending a zero move for each one fills the socket
    /// with nothing.
    func testAFingerThatDoesNotMoveSendsNothing() {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, [(1, 40, 40)], at: 100))
        XCTAssertEqual(interpreter.handle(event(.moved, [(1, 40, 40)], at: 100.01)), [])
    }

    /// Trap C. `dtMicros` comes from the event timestamps, not from a clock
    /// read inside the handler. Two moves of the same distance over different
    /// gaps must report different gaps, because the Mac divides one by the
    /// other to get the speed its acceleration curve needs.
    func testGapBetweenMovesComesFromTheEventTimestamps() {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, [(1, 0, 0)], at: 100))
        XCTAssertEqual(
            interpreter.handle(event(.moved, [(1, 10, 0)], at: 100.004)),
            [.pointerMove(dx: 10, dy: 0, dtMicros: 4_000)]
        )
        XCTAssertEqual(
            interpreter.handle(event(.moved, [(1, 20, 0)], at: 100.024)),
            [.pointerMove(dx: 10, dy: 0, dtMicros: 20_000)]
        )
    }

    /// The first move of a drag is measured from touch down, not from whenever
    /// the previous drag ended. Without this the first move of every drag
    /// carries the length of the pause between them.
    func testFirstMoveIsMeasuredFromTouchDown() {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, [(1, 0, 0)], at: 100))
        _ = interpreter.handle(event(.moved, [(1, 50, 0)], at: 100.01))
        _ = interpreter.handle(event(.ended, [], at: 100.02))
        // Five seconds of nothing, then a new drag.
        _ = interpreter.handle(event(.began, [(2, 0, 0)], at: 105))
        XCTAssertEqual(
            interpreter.handle(event(.moved, [(2, 3, 0)], at: 105.005)),
            [.pointerMove(dx: 3, dy: 0, dtMicros: 5_000)]
        )
    }

    /// Trap F. There is exactly one `MoveThrottle`, mutated in place. A copy
    /// would fork the sub-pixel accumulator, and a slow drag would stall
    /// instead of crossing the one point boundary.
    func testSubPixelMovesAccumulateAcrossEvents() {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, [(1, 0, 0)], at: 100))
        XCTAssertEqual(interpreter.handle(event(.moved, [(1, 0.4, 0)], at: 100.01)), [])
        XCTAssertEqual(interpreter.handle(event(.moved, [(1, 0.8, 0)], at: 100.02)), [])
        XCTAssertEqual(
            interpreter.handle(event(.moved, [(1, 1.2, 0)], at: 100.03)),
            [.pointerMove(dx: 1, dy: 0, dtMicros: 30_000)]
        )
    }

    // MARK: - Tap

    func testShortStillTouchEmitsAClick() {
        let interpreter = TouchInterpreter()
        XCTAssertEqual(tap(interpreter, from: 100, to: 100.1), [leftDown, leftUp])
    }

    /// A press held for four tenths of a second is a press, not a tap. Pins the
    /// duration threshold to something under 0.4 seconds.
    func testTouchHeldTooLongDoesNotClick() {
        let interpreter = TouchInterpreter()
        XCTAssertEqual(tap(interpreter, from: 100, to: 100.4), [])
    }

    /// The boundary is inclusive. Pinned against the constant so the test is
    /// not at the mercy of decimal rounding.
    func testTouchLastingExactlyTheTapLimitStillClicks() {
        let interpreter = TouchInterpreter()
        let end = 100 + TouchInterpreter.tapMaxDuration
        XCTAssertEqual(tap(interpreter, from: 100, to: end), [leftDown, leftUp])
    }

    func testTouchLastingJustOverTheTapLimitDoesNotClick() {
        let interpreter = TouchInterpreter()
        let end = 100 + TouchInterpreter.tapMaxDuration + 0.01
        XCTAssertEqual(tap(interpreter, from: 100, to: end), [])
    }

    /// A finger that slides across the glass and lifts is a drag, not a click.
    /// Pins the movement threshold to something under 40 points.
    func testTouchThatMovesTooFarDoesNotClick() {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, [(1, 0, 0)], at: 100))
        _ = interpreter.handle(event(.moved, [(1, 40, 0)], at: 100.05))
        XCTAssertEqual(interpreter.handle(event(.ended, [], at: 100.1)), [])
    }

    func testTouchThatMovesExactlyTheAllowedDistanceStillClicks() {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, [(1, 0, 0)], at: 100))
        _ = interpreter.handle(
            event(.moved, [(1, TouchInterpreter.tapMaxMovement, 0)], at: 100.05)
        )
        XCTAssertEqual(interpreter.handle(event(.ended, [], at: 100.1)), [leftDown, leftUp])
    }

    func testTouchThatMovesJustPastTheAllowedDistanceDoesNotClick() {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, [(1, 0, 0)], at: 100))
        _ = interpreter.handle(
            event(.moved, [(1, TouchInterpreter.tapMaxMovement + 0.5, 0)], at: 100.05)
        )
        XCTAssertEqual(interpreter.handle(event(.ended, [], at: 100.1)), [])
    }

    /// Measured from the furthest point reached, not from where the finger
    /// happened to be when it lifted. A finger that sweeps 40 points away and
    /// comes back has dragged the cursor across the screen; clicking at the end
    /// of that would click somewhere the user never aimed at.
    func testDistanceIsMeasuredFromTheFurthestPointReached() {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, [(1, 0, 0)], at: 100))
        _ = interpreter.handle(event(.moved, [(1, 40, 0)], at: 100.05))
        _ = interpreter.handle(event(.moved, [(1, 0, 0)], at: 100.08))
        XCTAssertEqual(interpreter.handle(event(.ended, [], at: 100.1)), [])
    }

    // MARK: - Tap then drag, which is what makes text selection work

    func testTouchDownJustAfterATapHoldsTheButton() {
        let interpreter = TouchInterpreter()
        tap(interpreter, from: 100, to: 100.1)
        XCTAssertEqual(interpreter.handle(event(.began, [(2, 0, 0)], at: 100.15)), [leftDown])
    }

    /// The full gesture. Down, up, down, move, up: one click, the button held,
    /// the moves, then the release. This is a drag-select in a text editor.
    func testTapThenDragSelectsWithTheButtonHeldThroughout() {
        let interpreter = TouchInterpreter()
        var sent: [ClientMessage] = []
        sent += interpreter.handle(event(.began, [(1, 0, 0)], at: 100))
        sent += interpreter.handle(event(.ended, [], at: 100.1))
        sent += interpreter.handle(event(.began, [(2, 0, 0)], at: 100.15))
        sent += interpreter.handle(event(.moved, [(2, 30, 0)], at: 100.16))
        sent += interpreter.handle(event(.ended, [], at: 100.4))

        XCTAssertEqual(sent, [
            leftDown, leftUp,
            leftDown,
            .pointerMove(dx: 30, dy: 0, dtMicros: 10_000),
            leftUp
        ])
    }

    /// The release of a held drag emits the button up and nothing else. An
    /// extra click pair here would deselect whatever was just selected.
    func testReleasingAHeldDragEmitsOnlyTheButtonUp() {
        let interpreter = TouchInterpreter()
        tap(interpreter, from: 100, to: 100.1)
        _ = interpreter.handle(event(.began, [(2, 0, 0)], at: 100.15))
        XCTAssertEqual(interpreter.handle(event(.ended, [], at: 100.2)), [leftUp])
    }

    func testTouchDownAtTheEdgeOfTheChainWindowStillHoldsTheButton() {
        let interpreter = TouchInterpreter()
        tap(interpreter, from: 100, to: 100.1)
        let begin = 100.1 + TouchInterpreter.dragChainWindow
        XCTAssertEqual(interpreter.handle(event(.began, [(2, 0, 0)], at: begin)), [leftDown])
    }

    func testTouchDownJustPastTheChainWindowDoesNotHoldTheButton() {
        let interpreter = TouchInterpreter()
        tap(interpreter, from: 100, to: 100.1)
        let begin = 100.1 + TouchInterpreter.dragChainWindow + 0.05
        XCTAssertEqual(interpreter.handle(event(.began, [(2, 0, 0)], at: begin)), [])
    }

    /// Pins the window to something under half a second, which is the Mac's own
    /// double click interval. A window longer than that would hold the button
    /// down for a second tap the Mac no longer counts as a double click.
    func testTouchDownHalfASecondAfterATapDoesNotHoldTheButton() {
        let interpreter = TouchInterpreter()
        tap(interpreter, from: 100, to: 100.1)
        XCTAssertEqual(interpreter.handle(event(.began, [(2, 0, 0)], at: 100.6)), [])
    }

    /// Only a tap opens the window. A long press followed by a second touch is
    /// two separate gestures, not a drag.
    func testTouchAfterALongPressDoesNotHoldTheButton() {
        let interpreter = TouchInterpreter()
        tap(interpreter, from: 100, to: 100.5)
        XCTAssertEqual(interpreter.handle(event(.began, [(2, 0, 0)], at: 100.55)), [])
    }

    /// One tap opens the window once. A second touch inside the window holds
    /// the button; a third, arriving after that touch dragged rather than
    /// tapped, must not.
    func testADraggedChainTouchDoesNotReopenTheWindow() {
        let interpreter = TouchInterpreter()
        tap(interpreter, from: 100, to: 100.1)
        _ = interpreter.handle(event(.began, [(2, 0, 0)], at: 100.15))
        _ = interpreter.handle(event(.moved, [(2, 60, 0)], at: 100.2))
        _ = interpreter.handle(event(.ended, [], at: 100.5))
        XCTAssertEqual(interpreter.handle(event(.began, [(3, 0, 0)], at: 100.55)), [])
    }

    // MARK: - Two finger scroll

    /// Trap D. Natural scrolling, matching the iPad itself: the content follows
    /// the fingers. Two fingers moving down the glass send a positive vertical
    /// delta, which macOS treats as a scroll up, which moves the content down
    /// with the fingers.
    func testTwoFingersMovingDownScrollTheContentDown() {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, [(1, 0, 0), (2, 100, 0)], at: 100))
        XCTAssertEqual(
            interpreter.handle(event(.moved, [(1, 0, 20), (2, 100, 20)], at: 100.01)),
            [.scroll(dx: 0, dy: 20)]
        )
    }

    /// The horizontal axis follows the same rule: the content moves with the
    /// fingers, so the sign passes through unchanged.
    func testTwoFingersMovingRightScrollTheContentRight() {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, [(1, 0, 0), (2, 100, 0)], at: 100))
        XCTAssertEqual(
            interpreter.handle(event(.moved, [(1, 15, 0), (2, 115, 0)], at: 100.01)),
            [.scroll(dx: 15, dy: 0)]
        )
    }

    /// Scroll follows the centroid of the fingers, so a pinch (fingers moving
    /// in opposite directions) scrolls nothing rather than jumping.
    func testScrollFollowsTheCentroidOfTheFingers() {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, [(1, 0, 0), (2, 100, 0)], at: 100))
        XCTAssertEqual(
            interpreter.handle(event(.moved, [(1, -30, 0), (2, 130, 0)], at: 100.01)),
            []
        )
    }

    func testTwoStillFingersScrollNothing() {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, [(1, 0, 0), (2, 100, 0)], at: 100))
        XCTAssertEqual(
            interpreter.handle(event(.moved, [(1, 0, 0), (2, 100, 0)], at: 100.01)),
            []
        )
    }

    /// `ClientMessage.scroll` carries `Int16`, and an `Int16(value)` conversion
    /// that does not fit traps rather than saturating, which on iOS means the
    /// app disappears mid-scroll. Scroll does not go through `MoveThrottle`, so
    /// it needs its own clamp.
    func testAnEnormousScrollDeltaClampsInsteadOfCrashing() {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, [(1, 0, 0), (2, 0, 0)], at: 100))
        XCTAssertEqual(
            interpreter.handle(event(.moved, [(1, 100_000, -100_000), (2, 100_000, -100_000)], at: 100.01)),
            [.scroll(dx: Int16.max, dy: Int16.min)]
        )
    }

    /// The same sub-pixel problem `MoveThrottle` solves for moves. Truncating
    /// each event would make a slow two finger scroll refuse to move at all.
    func testSlowScrollAccumulatesSubPixelRemainders() {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, [(1, 0, 0), (2, 0, 0)], at: 100))
        XCTAssertEqual(interpreter.handle(event(.moved, [(1, 0, 0.4), (2, 0, 0.4)], at: 100.01)), [])
        XCTAssertEqual(interpreter.handle(event(.moved, [(1, 0, 0.8), (2, 0, 0.8)], at: 100.02)), [])
        XCTAssertEqual(
            interpreter.handle(event(.moved, [(1, 0, 1.2), (2, 0, 1.2)], at: 100.03)),
            [.scroll(dx: 0, dy: 1)]
        )
    }

    // MARK: - Finger count transitions (trap B)

    /// A second finger landing far from the first must not be read as the first
    /// finger teleporting. That is a single enormous `pointerMove`, seen as the
    /// cursor flying across the screen for no reason.
    ///
    /// The first finger drifts a little in the same event, which is what really
    /// happens when a second finger lands. That drift is discarded with the
    /// gesture rather than sent: the event that changes the number of fingers
    /// ends one gesture and starts another, and reports no movement of its own.
    func testASecondFingerLandingDoesNotEmitAJumpMove() {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, [(1, 0, 0)], at: 100))
        _ = interpreter.handle(event(.moved, [(1, 20, 20)], at: 100.01))
        XCTAssertEqual(
            interpreter.handle(event(.began, [(1, 40, 60), (2, 600, 400)], at: 100.02)),
            []
        )
    }

    /// The mirror image. Lifting one of two fingers must not turn the gap
    /// between the centroid and the remaining finger into a scroll or a move.
    func testLiftingOneOfTwoFingersDoesNotEmitAJump() {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, [(1, 0, 0), (2, 600, 400)], at: 100))
        _ = interpreter.handle(event(.moved, [(1, 0, 10), (2, 600, 410)], at: 100.01))
        XCTAssertEqual(interpreter.handle(event(.ended, [(1, 0, 10)], at: 100.02)), [])
    }

    /// After the jump is suppressed, the remaining finger must still drive the
    /// cursor. Suppressing the transition by freezing the gesture would be a
    /// trackpad that dies whenever a second finger brushes it.
    func testTheRemainingFingerKeepsMovingTheCursor() {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, [(1, 0, 0), (2, 600, 400)], at: 100))
        _ = interpreter.handle(event(.ended, [(1, 0, 0)], at: 100.01))
        XCTAssertEqual(
            interpreter.handle(event(.moved, [(1, 12, 0)], at: 100.02)),
            [.pointerMove(dx: 12, dy: 0, dtMicros: 10_000)]
        )
    }

    /// Two fingers rarely leave the glass in the same event, so a two finger
    /// tap passes through a moment of one finger on its way to zero. If that
    /// moment were treated as an ordinary touch, every two finger tap would
    /// click. Nothing in the app asks for a two finger tap, so it must do
    /// nothing at all.
    func testATwoFingerTapDoesNotClick() {
        let interpreter = TouchInterpreter()
        var sent: [ClientMessage] = []
        sent += interpreter.handle(event(.began, [(1, 0, 0), (2, 100, 0)], at: 100))
        sent += interpreter.handle(event(.ended, [(1, 0, 0)], at: 100.05))
        sent += interpreter.handle(event(.ended, [], at: 100.06))
        XCTAssertEqual(sent, [])
    }

    /// Trap A, by a route that is not cancellation. A second finger landing
    /// while a tap-and-drag is held ends the drag, and the button must come up
    /// with it. Leaving it down would hold the mouse button through a scroll
    /// and every gesture after it.
    func testASecondFingerLandingReleasesAHeldButton() {
        let interpreter = TouchInterpreter()
        tap(interpreter, from: 100, to: 100.1)
        _ = interpreter.handle(event(.began, [(2, 0, 0)], at: 100.15))
        XCTAssertEqual(
            interpreter.handle(event(.began, [(2, 0, 0), (3, 300, 300)], at: 100.2)),
            [leftUp]
        )
    }

    /// A third finger landing re-baselines the scroll rather than reporting the
    /// centroid moving to meet it.
    func testAThirdFingerLandingDoesNotEmitAScrollJump() {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, [(1, 0, 0), (2, 100, 0)], at: 100))
        XCTAssertEqual(
            interpreter.handle(event(.began, [(1, 0, 0), (2, 100, 0), (3, 800, 0)], at: 100.01)),
            []
        )
    }

    // MARK: - Cancellation (trap A)

    /// The worst failure in the app. If the system cancels a touch while the
    /// button is held (a call arrives, a system edge gesture wins, the app goes
    /// to the background) and the button is only released in `ended`, the Mac's
    /// mouse button stays pressed forever. Every later move drag-selects, and
    /// nothing on screen explains why.
    func testCancellationReleasesAHeldButton() {
        let interpreter = TouchInterpreter()
        tap(interpreter, from: 100, to: 100.1)
        _ = interpreter.handle(event(.began, [(2, 0, 0)], at: 100.15))
        XCTAssertEqual(interpreter.handle(event(.cancelled, [], at: 100.2)), [leftUp])
    }

    /// A cancelled touch is not a tap, however short and still it was. The user
    /// did not finish it.
    func testCancellationDoesNotClick() {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, [(1, 0, 0)], at: 100))
        XCTAssertEqual(interpreter.handle(event(.cancelled, [], at: 100.05)), [])
    }

    /// A cancelled gesture must not leave a half open drag window behind, or
    /// the next touch silently holds the button down.
    func testCancellationClosesTheDragChainWindow() {
        let interpreter = TouchInterpreter()
        tap(interpreter, from: 100, to: 100.1)
        _ = interpreter.handle(event(.cancelled, [], at: 100.12))
        XCTAssertEqual(interpreter.handle(event(.began, [(2, 0, 0)], at: 100.15)), [])
    }

    /// After a cancellation the interpreter is back at rest. A stray move for a
    /// touch it has forgotten must not move the cursor.
    func testAMoveAfterCancellationDoesNotMoveTheCursor() {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, [(1, 0, 0)], at: 100))
        _ = interpreter.handle(event(.cancelled, [], at: 100.05))
        XCTAssertEqual(interpreter.handle(event(.moved, [(1, 500, 500)], at: 100.06)), [])
    }

    /// `releaseAll` is the same safety net for the case UIKit does not report
    /// at all: the app being sent to the background with a finger down.
    func testReleaseAllReleasesAHeldButton() {
        let interpreter = TouchInterpreter()
        tap(interpreter, from: 100, to: 100.1)
        _ = interpreter.handle(event(.began, [(2, 0, 0)], at: 100.15))
        XCTAssertEqual(interpreter.releaseAll(), [leftUp])
    }

    /// It runs alongside `touchesCancelled`, which usually fires for the same
    /// reason, so it must not send a second release the Mac would read as a
    /// second click.
    func testReleaseAllSendsNothingWhenNoButtonIsHeld() {
        let interpreter = TouchInterpreter()
        tap(interpreter, from: 100, to: 100.1)
        _ = interpreter.handle(event(.began, [(2, 0, 0)], at: 100.15))
        _ = interpreter.releaseAll()
        XCTAssertEqual(interpreter.releaseAll(), [])
    }
}
