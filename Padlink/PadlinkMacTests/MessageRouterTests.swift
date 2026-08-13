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
        XCTAssertEqual(synthesizer.calls, [.scroll(deltaX: 3, deltaY: -120)])
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
        router.handle(.pointerButton(button: .left, isDown: true))
        router.handle(.pointerButton(button: .left, isDown: false))
        router.handle(.pointerButton(button: .left, isDown: true))

        guard case let .button(_, _, _, clickCount) = synthesizer.calls.last else {
            return XCTFail("expected a button call")
        }
        XCTAssertEqual(clickCount, 2)
    }

    func testHelloAndPingAreIgnoredByTheRouter() {
        // These are handled by the service, not by input synthesis.
        router.handle(.hello(protocolVersion: 1, deviceName: "test"))
        router.handle(.ping(seq: 1))
        XCTAssertTrue(synthesizer.calls.isEmpty)
    }
}
