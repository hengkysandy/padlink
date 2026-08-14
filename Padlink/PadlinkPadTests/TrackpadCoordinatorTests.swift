// Padlink/PadlinkPadTests/TrackpadCoordinatorTests.swift
import XCTest
import UIKit
import PadlinkCore
@testable import PadlinkPad

/// `TrackpadView` itself cannot be tested: `UITouch` cannot be constructed, so
/// there is no way to feed it a gesture. `TrackpadCoordinator` is the seam that
/// can be. It is everything the view does once UIKit's touches have been turned
/// into `TouchEvent`s, which is the only part with any behaviour in it.
@MainActor
final class TrackpadCoordinatorTests: XCTestCase {

    /// Collects what the coordinator sends. A class rather than a captured
    /// local so the closure and the assertions look at the same storage.
    private final class Recorder {
        var sent: [ClientMessage] = []
    }

    private let leftDown = ClientMessage.pointerButton(button: .left, isDown: true)
    private let leftUp = ClientMessage.pointerButton(button: .left, isDown: false)

    private func began(_ id: Int, at timestamp: TimeInterval) -> TouchEvent {
        TouchEvent(
            phase: .began,
            active: [TouchSample(id: TouchID(id), location: .zero)],
            timestamp: timestamp
        )
    }

    private func ended(at timestamp: TimeInterval) -> TouchEvent {
        TouchEvent(phase: .ended, active: [], timestamp: timestamp)
    }

    /// Every message the interpreter returns reaches the send closure, in
    /// order. A click whose down and up arrive the other way round is not a
    /// click at all.
    func testEveryInterpretedMessageIsSentInOrder() {
        let recorder = Recorder()
        let coordinator = TrackpadCoordinator { recorder.sent.append($0) }

        coordinator.deliver(began(1, at: 100))
        coordinator.deliver(ended(at: 100.1))

        XCTAssertEqual(recorder.sent, [leftDown, leftUp])
    }

    /// Trap A again, at the layer that has to act on it.
    func testReleasingHeldInputSendsTheButtonUp() {
        let recorder = Recorder()
        let coordinator = TrackpadCoordinator { recorder.sent.append($0) }

        coordinator.deliver(began(1, at: 100))
        coordinator.deliver(ended(at: 100.1))
        recorder.sent.removeAll()
        coordinator.deliver(began(2, at: 100.15))
        recorder.sent.removeAll()

        coordinator.releaseHeldInput()

        XCTAssertEqual(recorder.sent, [leftUp])
    }

    /// The app going to the background with a finger down is the case UIKit is
    /// least reliable about reporting as a cancelled touch, and it is exactly
    /// when a stuck mouse button costs the most: the user cannot see the Mac to
    /// notice. The coordinator listens for it itself.
    func testResigningActiveReleasesAHeldButton() {
        let recorder = Recorder()
        let coordinator = TrackpadCoordinator { recorder.sent.append($0) }

        coordinator.deliver(began(1, at: 100))
        coordinator.deliver(ended(at: 100.1))
        coordinator.deliver(began(2, at: 100.15))
        recorder.sent.removeAll()

        NotificationCenter.default.post(
            name: UIApplication.willResignActiveNotification,
            object: nil
        )

        XCTAssertEqual(recorder.sent, [leftUp])
    }

    /// The observer must not outlive the coordinator. A dead coordinator that
    /// still answers the notification would send a stray button up into a
    /// later session.
    func testADeallocatedCoordinatorSendsNothing() {
        let recorder = Recorder()
        do {
            let coordinator = TrackpadCoordinator { recorder.sent.append($0) }
            coordinator.deliver(began(1, at: 100))
            coordinator.deliver(ended(at: 100.1))
            coordinator.deliver(began(2, at: 100.15))
        }
        recorder.sent.removeAll()

        NotificationCenter.default.post(
            name: UIApplication.willResignActiveNotification,
            object: nil
        )

        XCTAssertEqual(recorder.sent, [])
    }
}
