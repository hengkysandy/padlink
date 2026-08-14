// Padlink/PadlinkPadTests/ScanCodeFilterTests.swift
import XCTest
@testable import PadlinkPad

/// Which scanned codes are worth acting on.
///
/// `AVCaptureMetadataOutput` cannot be tested: there is no way to hand it a
/// frame, and the simulator has no camera to produce one. So the de-duplication
/// rule is pulled out of the delegate callback to here, where a frame is just an
/// array of strings.
///
/// The strings below are deliberately not pairing codes. A real one carries the
/// pre-shared key, and this repository is public.
final class ScanCodeFilterTests: XCTestCase {

    // MARK: - The reason this type exists

    /// The first sighting of a code is the one the user meant.
    func testAFreshCodeIsDelivered() {
        var filter = ScanCodeFilter()
        XCTAssertEqual(filter.accept(["code-a"]), ["code-a"])
    }

    /// The whole point.
    ///
    /// A QR code held in front of the camera is reported in every frame it can
    /// be seen in, which is dozens a second. Without this, one deliberate act by
    /// the user becomes dozens of parse attempts, dozens of saves, and dozens of
    /// connection attempts.
    func testACodeHeldInFrameIsDeliveredOnceAndNotAgain() {
        var filter = ScanCodeFilter()
        XCTAssertEqual(filter.accept(["code-a"]), ["code-a"])

        for _ in 0..<40 {
            XCTAssertEqual(filter.accept(["code-a"]), [])
        }
    }

    /// Two codes in the same frame are two different things the user could have
    /// meant, so neither is dropped on the first sighting.
    func testTwoCodesInOneFrameAreBothDelivered() {
        var filter = ScanCodeFilter()
        XCTAssertEqual(filter.accept(["code-a", "code-b"]), ["code-a", "code-b"])
    }

    /// Two codes in frame together must not flap.
    ///
    /// This is the case a single "last code seen" variable gets wrong. With one
    /// slot, code-a evicts code-b and code-b evicts code-a, so every frame
    /// re-delivers both and the de-duplication does nothing at all in exactly
    /// the situation it was written for. Anyone with a second QR code anywhere
    /// on the Mac's screen hits it.
    func testTwoCodesHeldInFrameTogetherDoNotFlap() {
        var filter = ScanCodeFilter()
        XCTAssertEqual(filter.accept(["code-a", "code-b"]), ["code-a", "code-b"])

        for _ in 0..<40 {
            XCTAssertEqual(filter.accept(["code-a", "code-b"]), [])
        }
    }

    /// A code that has already been delivered stays suppressed even when another
    /// code is seen in between. Re-reading it would produce the identical
    /// result, because parsing a code is deterministic.
    func testASecondCodeDoesNotUnsuppressTheFirst() {
        var filter = ScanCodeFilter()
        _ = filter.accept(["code-a"])
        XCTAssertEqual(filter.accept(["code-b"]), ["code-b"])
        XCTAssertEqual(filter.accept(["code-a"]), [])
    }

    /// A frame with no codes in it is the normal case: most frames see nothing.
    func testAnEmptyFrameDeliversNothing() {
        var filter = ScanCodeFilter()
        XCTAssertEqual(filter.accept([]), [])
    }

    /// Delivery order follows the frame, so the first code the camera reports is
    /// the first one acted on.
    func testDeliveryKeepsTheOrderTheFrameReportedThemIn() {
        var filter = ScanCodeFilter()
        XCTAssertEqual(filter.accept(["code-b", "code-a"]), ["code-b", "code-a"])
    }

    /// A frame can repeat a code inside itself. It is still one code.
    func testACodeRepeatedInsideOneFrameIsDeliveredOnce() {
        var filter = ScanCodeFilter()
        XCTAssertEqual(filter.accept(["code-a", "code-a"]), ["code-a"])
    }

    // MARK: - Starting over

    /// What `stop()` then `start()` relies on: leaving the pairing screen and
    /// coming back reads the same code again. Without this, a user who backs out
    /// of pairing and returns is pointing the camera at a code the app has
    /// decided to ignore, and the screen simply never responds.
    func testResumingAfterSuspendMakesAnAlreadySeenCodeReadableAgain() {
        var filter = ScanCodeFilter()
        XCTAssertEqual(filter.accept(["code-a"]), ["code-a"])
        XCTAssertEqual(filter.accept(["code-a"]), [])

        filter.suspend()
        filter.resume()

        XCTAssertEqual(filter.accept(["code-a"]), ["code-a"])
    }

    /// Suspending clears every code, not just the most recent one.
    func testSuspendForgetsAllCodesNotJustTheLast() {
        var filter = ScanCodeFilter()
        _ = filter.accept(["code-a", "code-b"])

        filter.suspend()
        filter.resume()

        XCTAssertEqual(filter.accept(["code-a", "code-b"]), ["code-a", "code-b"])
    }

    /// Suspending an untouched filter is not an error. `stop()` is called on
    /// screens that never started a session.
    func testSuspendOnAFilterThatHasSeenNothingIsHarmless() {
        var filter = ScanCodeFilter()
        filter.suspend()
        filter.resume()
        XCTAssertEqual(filter.accept(["code-a"]), ["code-a"])
    }

    // MARK: - Stopped means stopped

    /// Telling the session to stop does not stop frames arriving.
    ///
    /// `AVCaptureMetadataOutput` delivers on the main queue, and `stopRunning()`
    /// happens on the camera queue, so callbacks that were already queued still
    /// run after the app has decided to stop. Delivering those calls
    /// `submitPairing` for a screen the user has already left, which can pull the
    /// app forward to the trackpad after they pressed Back.
    func testACodeArrivingAfterSuspendIsNotDelivered() {
        var filter = ScanCodeFilter()
        filter.suspend()
        XCTAssertEqual(filter.accept(["code-a"]), [])
    }

    /// A brand new code, not just a repeat, is also dropped while suspended.
    /// Being stopped is about the session, not about what has been seen.
    func testAFreshCodeArrivingAfterSuspendIsNotDelivered() {
        var filter = ScanCodeFilter()
        _ = filter.accept(["code-a"])
        filter.suspend()
        XCTAssertEqual(filter.accept(["code-b"]), [])
    }

    /// A code dropped while suspended is not silently remembered as delivered.
    /// If it were, restarting the session would ignore the one code the camera
    /// is actually looking at.
    func testACodeDroppedWhileSuspendedIsStillReadableAfterResume() {
        var filter = ScanCodeFilter()
        filter.suspend()
        XCTAssertEqual(filter.accept(["code-a"]), [])

        filter.resume()

        XCTAssertEqual(filter.accept(["code-a"]), ["code-a"])
    }

    /// A fresh filter accepts. Nothing can reach it before the session starts,
    /// because the metadata delegate is only attached inside `configure()`.
    func testAFreshFilterIsAccepting() {
        var filter = ScanCodeFilter()
        XCTAssertEqual(filter.accept(["code-a"]), ["code-a"])
    }
}
