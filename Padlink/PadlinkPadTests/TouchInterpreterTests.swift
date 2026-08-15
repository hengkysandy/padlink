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
    private let rightDown = ClientMessage.pointerButton(button: .right, isDown: true)
    private let rightUp = ClientMessage.pointerButton(button: .right, isDown: false)

    /// A whole keystroke: down then up. Every swipe sends exactly one of these.
    private func stroke(_ key: PadlinkKey, _ modifiers: KeyModifiers) -> [ClientMessage] {
        [
            .keyCode(key: key, isDown: true, modifiers: modifiers),
            .keyCode(key: key, isDown: false, modifiers: modifiers)
        ]
    }

    /// `count` fingers in a row, 100 points apart, the whole row offset by
    /// `dx` and `dy`. The spread never changes, so this is always a swipe or a
    /// scroll and never a pinch.
    private func row(_ count: Int, dx: Double = 0, dy: Double = 0) -> [(Int, Double, Double)] {
        (0..<count).map { (index: Int) in (index + 1, Double(index) * 100 + dx, dy) }
    }

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

    /// A millisecond inside the window, not exactly on it. `100.1 + 0.45` is not
    /// exactly `100.55` in binary floating point, so a test sitting on the
    /// boundary measures the rounding of its own arithmetic rather than the
    /// rule. Which side of the boundary an exact hit falls on is not a
    /// requirement anybody has; being comfortably inside it is.
    func testTouchDownAtTheEdgeOfTheChainWindowStillHoldsTheButton() {
        let interpreter = TouchInterpreter()
        tap(interpreter, from: 100, to: 100.1)
        let begin = 100.1 + TouchInterpreter.dragChainWindow - 0.001
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

    /// Scroll follows the centroid of the fingers, so fingers moving in
    /// opposite directions never scroll: the centroid does not move at all.
    ///
    /// This used to be the whole story, and a pinch simply did nothing. It is
    /// now the first half of the pinch test below, kept separate because the
    /// reason a pinch does not scroll is worth pinning on its own: if the
    /// centroid maths ever changed, a pinch would scroll *and* zoom.
    func testAPinchNeverProducesAPlainScroll() {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, [(1, 0, 0), (2, 100, 0)], at: 100))
        let sent = interpreter.handle(event(.moved, [(1, -30, 0), (2, 130, 0)], at: 100.01))
        XCTAssertFalse(sent.contains { if case .scroll(let dx, _) = $0 { return dx != 0 }; return false })
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
    ///
    /// Measured past the decision threshold, because below it a two finger
    /// gesture has not yet chosen between scrolling and zooming and correctly
    /// sends neither. The point being pinned is that fractional steps add up
    /// rather than each being rounded away.
    func testSlowScrollAccumulatesSubPixelRemainders() {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, [(1, 0, 0), (2, 0, 0)], at: 100))
        // Past the threshold in one step, so the gesture is committed to
        // scrolling and every step after this one is a pure scroll.
        _ = interpreter.handle(event(.moved, [(1, 0, 20), (2, 0, 20)], at: 100.01))

        XCTAssertEqual(interpreter.handle(event(.moved, [(1, 0, 20.4), (2, 0, 20.4)], at: 100.02)), [])
        XCTAssertEqual(interpreter.handle(event(.moved, [(1, 0, 20.8), (2, 0, 20.8)], at: 100.03)), [])
        XCTAssertEqual(
            interpreter.handle(event(.moved, [(1, 0, 21.2), (2, 0, 21.2)], at: 100.04)),
            [.scroll(dx: 0, dy: 1)]
        )
    }

    /// The decision threshold delays a scroll; it must never eat one.
    ///
    /// Nine points of movement is below the threshold and sends nothing. The
    /// next event crosses it, and the scroll that comes out has to carry all
    /// fourteen points, not the five since the decision. Losing the front of
    /// every scroll reads as content lagging the fingers and never catching up,
    /// which is the kind of fault that gets described as "it feels wrong".
    func testMovementMadeWhileDecidingIsNotThrownAway() {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, [(1, 0, 0), (2, 100, 0)], at: 100))
        XCTAssertEqual(interpreter.handle(event(.moved, [(1, 0, 9), (2, 100, 9)], at: 100.01)), [])
        XCTAssertEqual(
            interpreter.handle(event(.moved, [(1, 0, 14), (2, 100, 14)], at: 100.02)),
            [.scroll(dx: 0, dy: 14)]
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
    ///
    /// Asserted as "no movement", not "no messages". Ten points in twenty
    /// milliseconds is within the tap allowance, so this is also a two finger
    /// tap and correctly right clicks. The jump is the thing being ruled out.
    func testLiftingOneOfTwoFingersDoesNotEmitAJump() {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, [(1, 0, 0), (2, 600, 400)], at: 100))
        _ = interpreter.handle(event(.moved, [(1, 0, 10), (2, 600, 410)], at: 100.01))
        let sent = interpreter.handle(event(.ended, [(1, 0, 10)], at: 100.02))
        XCTAssertFalse(sent.contains { message in
            switch message {
            case .pointerMove, .scroll: return true
            default: return false
            }
        })
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
    /// *left* click as well as right clicking, which on a Mac dismisses the
    /// context menu the right click just opened.
    func testATwoFingerTapRightClicksAndDoesNotAlsoLeftClick() {
        let interpreter = TouchInterpreter()
        var sent: [ClientMessage] = []
        sent += interpreter.handle(event(.began, [(1, 0, 0), (2, 100, 0)], at: 100))
        sent += interpreter.handle(event(.ended, [(1, 0, 0)], at: 100.05))
        sent += interpreter.handle(event(.ended, [], at: 100.06))
        XCTAssertEqual(sent, [rightDown, rightUp])
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

    // MARK: - Two finger tap, as a right click

    /// The plain case: both fingers leave in the same event.
    func testBothFingersLiftingTogetherRightClicks() {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, row(2), at: 100))
        XCTAssertEqual(interpreter.handle(event(.ended, [], at: 100.05)), [rightDown, rightUp])
    }

    /// Held too long is a press, not a tap. Matching the one finger rule, so
    /// there is one duration to remember rather than two.
    func testTwoFingersHeldTooLongDoNotRightClick() {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, row(2), at: 100))
        XCTAssertEqual(interpreter.handle(event(.ended, [], at: 100.5)), [])
    }

    /// A scroll that happens to end quickly is not a tap. Without this, a short
    /// flick would scroll *and* open a context menu on whatever it landed on.
    func testAShortScrollDoesNotAlsoRightClick() {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, row(2), at: 100))
        _ = interpreter.handle(event(.moved, row(2, dy: 30), at: 100.02))
        XCTAssertFalse(interpreter.handle(event(.ended, [], at: 100.05)).contains(rightDown))
    }

    /// The system taking the touches away is not a tap, for exactly the reason
    /// a cancelled one finger touch is not a click.
    func testACancelledTwoFingerTouchDoesNotRightClick() {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, row(2), at: 100))
        XCTAssertEqual(interpreter.handle(event(.cancelled, [], at: 100.05)), [])
    }

    /// A right click must not open the drag window. Chaining a held left button
    /// onto a context menu is not a gesture anyone makes, and the button would
    /// stay down through whatever the user did next.
    func testARightClickDoesNotArmTheDragChain() {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, row(2), at: 100))
        _ = interpreter.handle(event(.ended, [], at: 100.05))
        XCTAssertEqual(interpreter.handle(event(.began, [(9, 0, 0)], at: 100.1)), [])
    }

    // MARK: - Pinch to zoom

    /// macOS has no public API for synthesizing a real pinch, so a zoom is
    /// Command held across a scroll. Fingers spreading apart zoom in, which is
    /// a scroll up, which is a positive delta.
    func testFingersSpreadingApartZoomIn() {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, [(1, 0, 0), (2, 100, 0)], at: 100))
        let sent = interpreter.handle(event(.moved, [(1, -40, 0), (2, 140, 0)], at: 100.02))

        XCTAssertEqual(sent.first, .modifierState(modifiers: .command))
        // Second event, so the pre-decision spread change is not replayed and
        // this is a pure step.
        let more = interpreter.handle(event(.moved, [(1, -60, 0), (2, 160, 0)], at: 100.04))
        XCTAssertEqual(more, [.scroll(dx: 0, dy: 5)])
    }

    func testFingersComingTogetherZoomOut() {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, [(1, 0, 0), (2, 200, 0)], at: 100))
        _ = interpreter.handle(event(.moved, [(1, 40, 0), (2, 160, 0)], at: 100.02))
        XCTAssertEqual(
            interpreter.handle(event(.moved, [(1, 60, 0), (2, 140, 0)], at: 100.04)),
            [.scroll(dx: 0, dy: -5)]
        )
    }

    /// The single most dangerous thing in this file. Command left held on the
    /// Mac makes every later keystroke a shortcut, and the iPad has nothing on
    /// screen to say so.
    func testAZoomReleasesCommandWhenTheFingersLift() {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, [(1, 0, 0), (2, 100, 0)], at: 100))
        _ = interpreter.handle(event(.moved, [(1, -40, 0), (2, 140, 0)], at: 100.02))
        XCTAssertEqual(
            interpreter.handle(event(.ended, [], at: 100.1)).last,
            .modifierState(modifiers: [])
        )
    }

    /// The same, by the route that exists because the tidy one is not enough.
    func testACancelledZoomReleasesCommand() {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, [(1, 0, 0), (2, 100, 0)], at: 100))
        _ = interpreter.handle(event(.moved, [(1, -40, 0), (2, 140, 0)], at: 100.02))
        XCTAssertTrue(
            interpreter.handle(event(.cancelled, [], at: 100.1))
                .contains(.modifierState(modifiers: []))
        )
    }

    /// And by the route UIKit does not always report: the app going away with
    /// the fingers still down.
    func testReleaseAllReleasesAZoomsCommand() {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, [(1, 0, 0), (2, 100, 0)], at: 100))
        _ = interpreter.handle(event(.moved, [(1, -40, 0), (2, 140, 0)], at: 100.02))
        XCTAssertEqual(interpreter.releaseAll(), [.modifierState(modifiers: [])])
    }

    /// `modifierState` is absolute: it replaces the Mac's whole held set. If a
    /// zoom ended by sending an empty set, it would also release a Command the
    /// user had locked on the on screen keyboard, and the keyboard would go on
    /// showing it as locked while the Mac had let it go.
    func testAZoomRestoresTheKeyboardsLockedModifiersRatherThanClearingThem() {
        let interpreter = TouchInterpreter()
        interpreter.baseModifiers = .shift
        _ = interpreter.handle(event(.began, [(1, 0, 0), (2, 100, 0)], at: 100))

        XCTAssertEqual(
            interpreter.handle(event(.moved, [(1, -40, 0), (2, 140, 0)], at: 100.02)).first,
            .modifierState(modifiers: [.shift, .command])
        )
        XCTAssertEqual(
            interpreter.handle(event(.ended, [], at: 100.1)).last,
            .modifierState(modifiers: .shift)
        )
    }

    // MARK: - The readout

    /// The readout exists to tell three silent failures apart, so it has to be
    /// right about which one happened. These pin each answer.
    func testTheReadoutIsIdleWithNothingOnTheGlass() {
        XCTAssertEqual(TouchInterpreter().activity, .idle)
    }

    func testTheReadoutNamesAScroll() {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, row(2), at: 100))
        _ = interpreter.handle(event(.moved, row(2, dy: 30), at: 100.02))
        XCTAssertEqual(interpreter.activity, .scroll)
    }

    func testTheReadoutNamesAZoom() {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, [(1, 0, 0), (2, 100, 0)], at: 100))
        _ = interpreter.handle(event(.moved, [(1, 0, 0), (2, 160, 0)], at: 100.02))
        XCTAssertEqual(interpreter.activity, .zoom)
    }

    /// The count comes from the interpreter, not from the raw touch list, so it
    /// says how many fingers were understood rather than how many were sent.
    func testTheReadoutCountsThreeFingersAndSaysTheSwipeFired() {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, row(3), at: 100))
        XCTAssertEqual(interpreter.activity, .multi(fingers: 3, fired: false))

        _ = interpreter.handle(event(.moved, row(3, dy: -60), at: 100.05))
        XCTAssertEqual(interpreter.activity, .multi(fingers: 3, fired: true))
    }

    /// The single most useful thing the readout can say. iPadOS taking the
    /// touches away is invisible from the chair and looks exactly like the
    /// gesture never having been built, which is how three finger swipes
    /// shipped dead once already.
    func testTheReadoutSaysWhenTheSystemTookTheTouchesAway() {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, row(3), at: 100))
        _ = interpreter.handle(event(.cancelled, [], at: 100.05))
        XCTAssertEqual(interpreter.activity, .cancelled)
    }

    /// And that it survives long enough to be read. A cancellation ends with no
    /// fingers on the glass, so anything that reset it to idle in the same
    /// breath would leave nothing on screen.
    func testACancellationIsStillReadableAfterTheFingersAreGone() {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, row(3), at: 100))
        _ = interpreter.handle(event(.cancelled, [], at: 100.05))
        XCTAssertEqual(interpreter.activity.label, "cancelled by iPadOS")

        // Cleared by the next real touch, not by time.
        _ = interpreter.handle(event(.began, [(9, 0, 0)], at: 101))
        XCTAssertEqual(interpreter.activity, .pointer)
    }

    /// The pinch nobody makes in a lab and everybody makes on a device: one
    /// finger stays put and the other one moves.
    ///
    /// Every other zoom test here moves both fingers by the same amount, which
    /// holds the centroid perfectly still and hands the decision to the spread
    /// unopposed. That is the one pinch shape that always worked, and testing
    /// only that shape is how zoom shipped dead.
    ///
    /// Anchoring the thumb splits the movement in half: the separation grows by
    /// the full distance and the centroid moves by half of it. So the decision
    /// only comes out as a zoom if the spread is measured as the real distance
    /// between the fingers, not as the mean distance from the centroid, which
    /// is exactly half of it and ties with the centroid's own travel.
    func testAPinchWithOneFingerAnchoredStillZooms() {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, [(1, 0, 0), (2, 100, 0)], at: 100))
        let sent = interpreter.handle(event(.moved, [(1, 0, 0), (2, 160, 0)], at: 100.02))

        XCTAssertTrue(
            sent.contains { if case .modifierState = $0 { return true }; return false },
            "an anchored pinch was read as a scroll, so zoom never fires on a real hand"
        )
    }

    /// The same shape pinching inward, which is the half people actually use
    /// to zoom back out of a photo.
    func testAnAnchoredPinchInwardStillZooms() {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, [(1, 0, 0), (2, 200, 0)], at: 100))
        let sent = interpreter.handle(event(.moved, [(1, 0, 0), (2, 140, 0)], at: 100.02))

        XCTAssertTrue(
            sent.contains { if case .modifierState = $0 { return true }; return false },
            "an anchored pinch inward was read as a scroll"
        )
    }

    /// The guard on the fix. Making the spread twice as sensitive must not make
    /// an ordinary two finger scroll start zooming, because a scroll always
    /// changes the spread a little as the hand rolls.
    func testASlightlyUnevenScrollIsStillAScroll() {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, [(1, 0, 0), (2, 100, 0)], at: 100))
        // Both fingers down the glass by 40, one of them drifting 6 points
        // wider, which is the ordinary sloppiness of a real two finger scroll.
        let sent = interpreter.handle(event(.moved, [(1, 0, 40), (2, 106, 40)], at: 100.02))

        XCTAssertFalse(
            sent.contains { if case .modifierState = $0 { return true }; return false },
            "a sloppy scroll was read as a pinch"
        )
    }

    /// A gesture commits to one meaning and keeps it. Deciding afresh every
    /// frame makes a slow diagonal pinch flicker between zooming and scrolling,
    /// which is unusable and looks like a fault on the Mac.
    func testAGestureThatBecameAZoomNeverStartsScrolling() {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, [(1, 0, 0), (2, 100, 0)], at: 100))
        _ = interpreter.handle(event(.moved, [(1, -40, 0), (2, 140, 0)], at: 100.02))
        // Now slide the whole pair sideways, which on its own is a clear scroll.
        let sent = interpreter.handle(event(.moved, [(1, 60, 0), (2, 240, 0)], at: 100.04))
        // Still exactly one message, and the spread did not change, so it is
        // the zoom's own zero step and not a horizontal scroll.
        XCTAssertFalse(sent.contains { if case .scroll(let dx, _) = $0 { return dx != 0 }; return false })
    }

    func testAGestureThatBecameAScrollNeverStartsZooming() {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, [(1, 0, 0), (2, 100, 0)], at: 100))
        _ = interpreter.handle(event(.moved, row(2, dy: 30), at: 100.02))
        // Now spread the fingers hard, which on its own is a clear pinch.
        let sent = interpreter.handle(event(.moved, [(1, -100, 30), (2, 200, 30)], at: 100.04))
        XCTAssertFalse(sent.contains { if case .modifierState = $0 { return true }; return false })
    }

    // MARK: - Three and four finger swipes

    func testThreeFingersUpOpensMissionControl() {
        XCTAssertEqual(swipe(fingers: 3, dx: 0, dy: -60), stroke(.arrowUp, .control))
    }

    func testThreeFingersDownOpensAppExpose() {
        XCTAssertEqual(swipe(fingers: 3, dx: 0, dy: 60), stroke(.arrowDown, .control))
    }

    /// Swiping right pulls the previous page back in from the left, matching
    /// natural scrolling and Safari's own gesture.
    func testThreeFingersRightGoesBack() {
        XCTAssertEqual(swipe(fingers: 3, dx: 60, dy: 0), stroke(.leftBracket, .command))
    }

    func testThreeFingersLeftGoesForward() {
        XCTAssertEqual(swipe(fingers: 3, dx: -60, dy: 0), stroke(.rightBracket, .command))
    }

    /// Four fingers sideways switches spaces rather than pages. Keeping the
    /// counts apart is what lets both exist: overloading one would mean
    /// guessing whether a sideways swipe meant "go back" or "next desktop".
    func testFourFingersLeftMovesToTheNextSpace() {
        XCTAssertEqual(swipe(fingers: 4, dx: -60, dy: 0), stroke(.arrowRight, .control))
    }

    func testFourFingersRightMovesToThePreviousSpace() {
        XCTAssertEqual(swipe(fingers: 4, dx: 60, dy: 0), stroke(.arrowLeft, .control))
    }

    /// Vertical is Mission Control for both counts, which is what macOS does
    /// and what everyone's muscle memory expects.
    func testFourFingersUpAlsoOpensMissionControl() {
        XCTAssertEqual(swipe(fingers: 4, dx: 0, dy: -60), stroke(.arrowUp, .control))
    }

    /// A swipe fires a keystroke that changes the whole screen, and the iPad
    /// cannot take it back. A short movement must not be enough.
    func testAShortThreeFingerMovementFiresNothing() {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, row(3), at: 100))
        XCTAssertEqual(interpreter.handle(event(.moved, row(3, dy: -30), at: 100.05)), [])
    }

    /// One swipe, one keystroke. Without this a long three finger swipe would
    /// fire on every frame past the threshold and switch four spaces.
    func testALongSwipeFiresExactlyOnce() {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, row(3), at: 100))
        XCTAssertEqual(
            interpreter.handle(event(.moved, row(3, dy: -60), at: 100.05)),
            stroke(.arrowUp, .control)
        )
        XCTAssertEqual(interpreter.handle(event(.moved, row(3, dy: -200), at: 100.1)), [])
        XCTAssertEqual(interpreter.handle(event(.moved, row(3, dy: -400), at: 100.15)), [])
    }

    /// Three fingers never move the cursor and never scroll. Falling back to
    /// either would make a swipe that did not travel far enough scroll the page
    /// underneath it instead of doing nothing.
    func testThreeFingersNeverScroll() {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, row(3), at: 100))
        let sent = interpreter.handle(event(.moved, row(3, dy: 20), at: 100.02))
        XCTAssertEqual(sent, [])
    }

    /// Lifting to two fingers mid-swipe starts a fresh two finger gesture
    /// rather than continuing the swipe, so the released finger cannot leave a
    /// half-finished gesture that fires later.
    func testDroppingToTwoFingersEndsTheSwipe() {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, row(3), at: 100))
        _ = interpreter.handle(event(.moved, row(3, dy: -20), at: 100.02))
        XCTAssertEqual(interpreter.handle(event(.ended, row(2, dy: -20), at: 100.04)), [])
        // A further 60 points would have fired the swipe if the swipe were
        // still running. It is a scroll now.
        XCTAssertEqual(
            interpreter.handle(event(.moved, row(2, dy: -80), at: 100.06)),
            [.scroll(dx: 0, dy: -60)]
        )
    }

    /// Five fingers is a hand resting while three swipe, which is common. It is
    /// treated as four rather than ignored: doing nothing at all reads as the
    /// gesture being broken.
    func testFiveFingersBehaveAsFour() {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, row(5), at: 100))
        XCTAssertEqual(
            interpreter.handle(event(.moved, row(5, dx: -60), at: 100.05)),
            stroke(.arrowRight, .control)
        )
    }

    /// Runs one whole swipe and returns what it sent.
    private func swipe(fingers: Int, dx: Double, dy: Double) -> [ClientMessage] {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, row(fingers), at: 100))
        return interpreter.handle(event(.moved, row(fingers, dx: dx, dy: dy), at: 100.05))
    }

    // MARK: - Momentum

    /// A flick keeps scrolling after the fingers leave, the way a real trackpad
    /// does. The interpreter holds no clock: the view drives each step with a
    /// timestamp, so a test can choose them.
    func testAFlickKeepsScrollingAfterTheFingersLift() {
        let interpreter = flick()
        XCTAssertTrue(interpreter.hasMomentum)
        XCTAssertFalse(interpreter.stepMomentum(at: 100.056).isEmpty)
    }

    /// A scroll that came to rest before lifting means the user stopped on
    /// purpose. Coasting anyway is the trackpad ignoring a deliberate stop.
    func testAScrollThatStoppedBeforeLiftingDoesNotCoast() {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, row(2), at: 100))
        _ = interpreter.handle(event(.moved, row(2, dy: 40), at: 100.02))
        // Held still for a fifth of a second, then lifted.
        _ = interpreter.handle(event(.moved, row(2, dy: 40), at: 100.2))
        _ = interpreter.handle(event(.ended, [], at: 100.25))
        XCTAssertFalse(interpreter.hasMomentum)
    }

    /// A slow scroll has nothing to carry. Coasting from a gentle drag makes
    /// the content keep sliding after the user has stopped reading.
    func testASlowScrollDoesNotCoast() {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, row(2), at: 100))
        _ = interpreter.handle(event(.moved, row(2, dy: 20), at: 100.2))
        _ = interpreter.handle(event(.moved, row(2, dy: 22), at: 100.4))
        _ = interpreter.handle(event(.ended, [], at: 100.42))
        XCTAssertFalse(interpreter.hasMomentum)
    }

    /// Momentum has to stop by itself. Without a floor it creeps forward for
    /// several seconds at a speed the user cannot see but the Mac can.
    func testMomentumStopsOnItsOwn() {
        let interpreter = flick()
        var time: TimeInterval = 100.05
        for _ in 0..<200 {
            time += 1.0 / 60
            _ = interpreter.stepMomentum(at: time)
        }
        XCTAssertFalse(interpreter.hasMomentum)
        XCTAssertEqual(interpreter.stepMomentum(at: time + 1), [])
    }

    /// Momentum decays. Two steps the same size apart must not send the same
    /// amount, or it is not momentum, it is a scroll that never stops.
    func testMomentumSlowsDown() {
        let interpreter = flick()
        var first = 0
        var last = 0
        var time: TimeInterval = 100.05
        for index in 0..<20 {
            time += 1.0 / 60
            for message in interpreter.stepMomentum(at: time) {
                if case let .scroll(_, dy) = message {
                    if index == 0 { first = abs(Int(dy)) }
                    last = abs(Int(dy))
                }
            }
        }
        XCTAssertGreaterThan(first, last)
    }

    /// Putting a finger down stops the coast, exactly as it does on a real
    /// trackpad. Anything else means a tap lands on content that is still
    /// moving under it.
    func testATouchStopsMomentum() {
        let interpreter = flick()
        XCTAssertTrue(interpreter.hasMomentum)
        _ = interpreter.handle(event(.began, [(9, 0, 0)], at: 100.06))
        XCTAssertFalse(interpreter.hasMomentum)
    }

    func testReleaseAllStopsMomentum() {
        let interpreter = flick()
        _ = interpreter.releaseAll()
        XCTAssertFalse(interpreter.hasMomentum)
    }

    /// The display link stalls whenever the app is interrupted. One huge `dt`
    /// must not turn a flick into a single enormous jump.
    ///
    /// `dt` is clamped to a tenth of a second, so one step can never send more
    /// than a tenth of a second of scrolling however long the app was away.
    /// Thirty seconds unclamped would be thousands of points in one message.
    func testAStalledDisplayLinkDoesNotProduceAGiantJump() {
        let interpreter = flick()
        let sent = interpreter.stepMomentum(at: 130)
        for message in sent {
            if case let .scroll(_, dy) = message {
                XCTAssertLessThan(abs(Int(dy)), 300)
            }
        }
    }

    /// A two finger flick downwards, lifted while still moving.
    private func flick() -> TouchInterpreter {
        let interpreter = TouchInterpreter()
        _ = interpreter.handle(event(.began, row(2), at: 100))
        for step in 1...5 {
            _ = interpreter.handle(
                event(.moved, row(2, dy: Double(step) * 30), at: 100 + Double(step) * 0.01)
            )
        }
        _ = interpreter.handle(event(.ended, [], at: 100.05))
        return interpreter
    }
}
