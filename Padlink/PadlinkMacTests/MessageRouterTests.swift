// Padlink/PadlinkMacTests/MessageRouterTests.swift
import XCTest
import PadlinkCore
@testable import PadlinkMac

final class MessageRouterTests: XCTestCase {
    private var synthesizer: RecordingSynthesizer!
    private var router: MessageRouter!

    override func setUp() {
        super.setUp()
        synthesizer = RecordingSynthesizer()
        router = MessageRouter(
            synthesizer: synthesizer,
            geometry: ScreenGeometry(topLeftFrames: [CGRect(x: 0, y: 0, width: 1440, height: 900)])
        )
    }

    func testPointerMoveWithNoButtonHeldIsAMove() {
        router.handle(.pointerMove(dx: 10, dy: 0, dtMicros: 16_666))
        guard case let .move(_, dragging) = synthesizer.calls.first else {
            return XCTFail("expected a move, got \(synthesizer.calls)")
        }
        XCTAssertNil(dragging)
    }

    func testPointerMoveWhileAButtonIsHeldIsADrag() {
        // The gotcha this test exists for: many apps ignore plain moves during
        // a drag, so text selection and window dragging would silently break.
        router.handle(.pointerButton(button: .left, isDown: true))
        router.handle(.pointerMove(dx: 10, dy: 0, dtMicros: 16_666))

        guard case let .move(_, dragging) = synthesizer.calls.last else {
            return XCTFail("expected a move, got \(synthesizer.calls)")
        }
        XCTAssertEqual(dragging, .left)
    }

    func testPointerMoveIsClampedToTheScreen() {
        synthesizer.cursorLocation = CGPoint(x: 1439, y: 400)
        router.handle(.pointerMove(dx: 32_000, dy: 0, dtMicros: 16_666))

        guard case let .move(point, _) = synthesizer.calls.first else {
            return XCTFail("expected a move")
        }
        XCTAssertLessThanOrEqual(point.x, 1439)
    }

    func testPlainTextTakesTheUnicodePath() {
        router.handle(.keyText("hello"))
        XCTAssertEqual(synthesizer.calls, [.insertText("hello")])
    }

    func testAKeyCodeMessageTakesTheVirtualKeyPath() {
        router.handle(.keyCode(key: .c, isDown: true, modifiers: [.command]))
        XCTAssertEqual(
            synthesizer.calls,
            [.key(virtualCode: MacVirtualKeys.code(for: .c), isDown: true, modifiers: [.command])]
        )
    }

    func testScrollIsForwarded() {
        router.handle(.scroll(dx: 3, dy: -120))
        XCTAssertEqual(synthesizer.calls, [.scroll(deltaX: 3, deltaY: -120, modifiers: [])])
    }

    /// The Mac half of pinch to zoom.
    ///
    /// A zoom is Command held across a scroll, and "held" is not enough on its
    /// own. macOS decides whether a scroll zooms by reading the modifier flags
    /// **on the scroll event itself**, so a Command posted as a separate key
    /// event leaves the scroll that follows it flagless and ordinary. The iPad
    /// can get the whole gesture right and the Mac will still just scroll.
    func testAScrollCarriesTheModifiersTheMacIsHolding() {
        router.handle(.modifierState(modifiers: [.command]))
        router.handle(.scroll(dx: 0, dy: 12))

        XCTAssertEqual(
            synthesizer.calls.last,
            .scroll(deltaX: 0, deltaY: 12, modifiers: [.command]),
            "a scroll during a zoom reached macOS with no Command flag on it"
        )
    }

    /// And gives them back, so the scroll after a pinch is a plain scroll.
    func testAScrollAfterTheModifiersAreReleasedCarriesNone() {
        router.handle(.modifierState(modifiers: [.command]))
        router.handle(.modifierState(modifiers: []))
        router.handle(.scroll(dx: 0, dy: 12))

        XCTAssertEqual(synthesizer.calls.last, .scroll(deltaX: 0, deltaY: 12, modifiers: []))
    }

    /// A system action is passed straight through, and holds nothing.
    ///
    /// It exists because macOS ignores a synthesized event for a hotkey the
    /// Dock owns, so Mission Control cannot be reached as Control and Up.
    func testASystemActionIsPerformedRatherThanTypedOut() {
        router.handle(.systemAction(.missionControl))
        XCTAssertEqual(synthesizer.calls, [.systemAction(.missionControl)])
    }

    /// Nothing to release afterwards. A held key or button has a matching
    /// release that can leak; this does not, and `releaseEverything` must not
    /// invent one.
    func testASystemActionLeavesNothingHeld() {
        router.handle(.systemAction(.missionControl))
        router.releaseEverything()
        XCTAssertEqual(synthesizer.calls, [.systemAction(.missionControl)])
    }

    // MARK: - Pinch

    /// A pinch goes straight through as a real gesture.
    ///
    /// It used to be Command held across a scroll, which is what a mouse wheel
    /// user does and not what a trackpad does. Measured on real hardware: that
    /// zooms Chrome and does nothing in Preview, Photos, Maps or Xcode.
    func testAPinchIsPassedThroughAsAGesture() {
        router.handle(.pinch(phase: .began, magnification: 0))
        router.handle(.pinch(phase: .changed, magnification: 120))
        router.handle(.pinch(phase: .ended, magnification: 0))

        XCTAssertEqual(synthesizer.calls, [
            .pinch(phase: .began, magnification: 0),
            .pinch(phase: .changed, magnification: 120),
            .pinch(phase: .ended, magnification: 0)
        ])
    }

    /// The stuck gesture case, which is the pinch equivalent of a stuck mouse
    /// button. An app told a pinch began and never told it ended goes on
    /// believing the fingers are still there.
    func testAPinchLeftOpenByADroppedConnectionIsClosed() {
        router.handle(.pinch(phase: .began, magnification: 0))
        router.handle(.pinch(phase: .changed, magnification: 50))
        let countBefore = synthesizer.calls.count

        router.releaseEverything()

        XCTAssertEqual(
            Array(synthesizer.calls.dropFirst(countBefore)),
            [.pinch(phase: .ended, magnification: 0)]
        )
    }

    /// And the other branch, so the fix cannot be "always end a pinch".
    func testAPinchThatAlreadyEndedIsNotEndedTwice() {
        router.handle(.pinch(phase: .began, magnification: 0))
        router.handle(.pinch(phase: .ended, magnification: 0))
        let countBefore = synthesizer.calls.count

        router.releaseEverything()

        XCTAssertEqual(synthesizer.calls.count, countBefore)
    }

    func testModifierStatePostsOnlyWhatChanged() {
        router.handle(.modifierState(modifiers: [.command]))
        XCTAssertEqual(synthesizer.calls, [.modifierKey(.command, isDown: true)])

        // Adding shift must not re-post command.
        router.handle(.modifierState(modifiers: [.command, .shift]))
        XCTAssertEqual(synthesizer.calls.last, .modifierKey(.shift, isDown: true))
        XCTAssertEqual(synthesizer.calls.count, 2)

        // Dropping command must release only command.
        router.handle(.modifierState(modifiers: [.shift]))
        XCTAssertEqual(synthesizer.calls.last, .modifierKey(.command, isDown: false))
        XCTAssertEqual(synthesizer.calls.count, 3)
    }

    func testRepeatingTheSameModifierStatePostsNothing() {
        router.handle(.modifierState(modifiers: [.command]))
        let countAfterFirst = synthesizer.calls.count
        router.handle(.modifierState(modifiers: [.command]))
        XCTAssertEqual(synthesizer.calls.count, countAfterFirst)
    }

    func testReleaseEverythingReleasesAHeldButtonAndModifier() {
        // This is the stuck-Command-key case.
        router.handle(.pointerButton(button: .left, isDown: true))
        router.handle(.modifierState(modifiers: [.command]))
        let countBefore = synthesizer.calls.count

        router.releaseEverything()

        let releases = Array(synthesizer.calls.dropFirst(countBefore))
        XCTAssertTrue(releases.contains(where: {
            if case .button(.left, isDown: false, _, _) = $0 { return true }
            return false
        }))
        XCTAssertTrue(releases.contains(.modifierKey(.command, isDown: false)))
    }

    // MARK: - Releasing a held key code
    //
    // A key down and its matching key up are two separate frames. A connection
    // dying between them leaves that key down at the HID level, and the Mac
    // repeats the character into whatever has focus. Quitting Padlink does not
    // stop it, because by then the key press does not belong to Padlink.

    func testReleaseEverythingReleasesAHeldKey() {
        router.handle(.keyCode(key: .a, isDown: true, modifiers: []))
        let countBefore = synthesizer.calls.count

        router.releaseEverything()

        XCTAssertEqual(
            Array(synthesizer.calls.dropFirst(countBefore)),
            [.key(virtualCode: MacVirtualKeys.code(for: .a), isDown: false, modifiers: [])],
            "a key the peer left down must be released when the connection ends"
        )
    }

    /// The other branch, so the fix cannot be "release every key every time".
    func testAKeyThePeerAlreadyReleasedIsNotReleasedAgain() {
        router.handle(.keyCode(key: .a, isDown: true, modifiers: []))
        router.handle(.keyCode(key: .a, isDown: false, modifiers: []))
        let countBefore = synthesizer.calls.count

        router.releaseEverything()

        XCTAssertEqual(synthesizer.calls.count, countBefore)
    }

    func testReleaseEverythingReleasesTheKeyBeforeItsModifier() {
        // Command held with Tab down is what the app switcher produces.
        // Releasing Command first leaves a bare Tab still held and repeating.
        router.handle(.modifierState(modifiers: [.command]))
        router.handle(.keyCode(key: .tab, isDown: true, modifiers: [.command]))
        let countBefore = synthesizer.calls.count

        router.releaseEverything()

        XCTAssertEqual(
            Array(synthesizer.calls.dropFirst(countBefore)),
            [
                .key(virtualCode: MacVirtualKeys.code(for: .tab), isDown: false, modifiers: []),
                .modifierKey(.command, isDown: false)
            ]
        )
    }

    func testReleaseEverythingTwiceDoesNothingTheSecondTime() {
        router.handle(.pointerButton(button: .left, isDown: true))
        router.releaseEverything()
        let countAfterFirst = synthesizer.calls.count

        router.releaseEverything()
        XCTAssertEqual(synthesizer.calls.count, countAfterFirst)
    }

    func testReleaseEverythingWithNothingHeldPostsNothing() {
        router.releaseEverything()
        XCTAssertTrue(synthesizer.calls.isEmpty)
    }

    func testTwoQuickClicksAreReportedAsADoubleClick() {
        // Pinned on all three calls, not just the last, so a regression that
        // moves the increment-and-interval-check into the up branch (leaving
        // the down branch to only record time and button) cannot hide behind
        // this exact sequence. That mistake still ends on clickCount == 2 for
        // the final call, but reports the up event's clickCount as 2 as
        // well, which is wrong: a single click's up must never look like a
        // double click.
        router.handle(.pointerButton(button: .left, isDown: true))
        guard case let .button(_, _, _, firstDownCount) = synthesizer.calls[0] else {
            return XCTFail("expected a button call")
        }
        XCTAssertEqual(firstDownCount, 1)

        router.handle(.pointerButton(button: .left, isDown: false))
        guard case let .button(_, _, _, upCount) = synthesizer.calls[1] else {
            return XCTFail("expected a button call")
        }
        XCTAssertEqual(upCount, 1)

        router.handle(.pointerButton(button: .left, isDown: true))
        guard case let .button(_, _, _, secondDownCount) = synthesizer.calls[2] else {
            return XCTFail("expected a button call")
        }
        XCTAssertEqual(secondDownCount, 2)
    }

    func testReleaseEverythingUsesTheCurrentCursorLocation() {
        // releaseEverything() must read the cursor location fresh, not reuse
        // whatever point was current when the button went down. Otherwise a
        // release after the pointer has moved posts the wrong coordinates.
        router.handle(.pointerButton(button: .left, isDown: true))
        let newLocation = CGPoint(x: 999, y: 42)
        synthesizer.cursorLocation = newLocation

        router.releaseEverything()

        guard case let .button(.left, isDown: false, at: point, _) = synthesizer.calls.last else {
            return XCTFail("expected a button release, got \(synthesizer.calls)")
        }
        XCTAssertEqual(point, newLocation)
    }

    func testClickCountResetsAfterTheDoubleClickIntervalElapses() {
        var currentTime = Date(timeIntervalSince1970: 0)
        let clockedRouter = MessageRouter(
            synthesizer: synthesizer,
            geometry: ScreenGeometry(topLeftFrames: [CGRect(x: 0, y: 0, width: 1440, height: 900)]),
            now: { currentTime }
        )

        clockedRouter.handle(.pointerButton(button: .left, isDown: true))
        // Longer than the 0.5 second double-click interval.
        currentTime = currentTime.addingTimeInterval(1.0)
        clockedRouter.handle(.pointerButton(button: .left, isDown: true))

        guard case let .button(_, _, _, clickCount) = synthesizer.calls.last else {
            return XCTFail("expected a button call")
        }
        XCTAssertEqual(clickCount, 1)
    }

    func testHelloAndPingAreIgnoredByTheRouter() {
        // These are handled by the service, not by input synthesis.
        router.handle(.hello(protocolVersion: 1, deviceName: "test"))
        router.handle(.ping(seq: 1))
        XCTAssertTrue(synthesizer.calls.isEmpty)
    }
}
