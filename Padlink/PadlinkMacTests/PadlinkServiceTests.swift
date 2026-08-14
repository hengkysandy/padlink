// Padlink/PadlinkMacTests/PadlinkServiceTests.swift
import XCTest
import PadlinkCore
@testable import PadlinkMac

@MainActor
final class PadlinkServiceTests: XCTestCase {
    private func makeService(store: any PairingStore = InMemoryPairingStore()) -> PadlinkService {
        PadlinkService(
            store: store,
            router: MessageRouter(
                synthesizer: RecordingSynthesizer(),
                geometry: ScreenGeometry(topLeftFrames: [CGRect(x: 0, y: 0, width: 1440, height: 900)])
            ),
            macName: "Test Mac"
        )
    }

    /// Builds a service over a router the test can inspect, with the left
    /// mouse button already held, which is what a user mid-drag looks like.
    private func serviceHoldingTheLeftButton() -> (PadlinkService, RecordingSynthesizer) {
        let synthesizer = RecordingSynthesizer()
        let router = MessageRouter(
            synthesizer: synthesizer,
            geometry: ScreenGeometry(topLeftFrames: [CGRect(x: 0, y: 0, width: 1440, height: 900)])
        )
        let service = PadlinkService(
            store: InMemoryPairingStore(),
            router: router,
            macName: "Test Mac"
        )
        router.handle(.pointerButton(button: .left, isDown: true))
        return (service, synthesizer)
    }

    private func assertLeftButtonWasReleased(
        _ synthesizer: RecordingSynthesizer,
        _ message: String,
        line: UInt = #line
    ) {
        let released = synthesizer.calls.contains { call in
            if case .button(.left, isDown: false, _, _) = call { return true }
            return false
        }
        XCTAssertTrue(released, message, line: line)
    }

    // MARK: - Releasing held input when a connection ends
    //
    // The worst failure this app can produce. A stuck mouse button is not a
    // Padlink problem the user can quit their way out of: it is posted at the
    // HID level, so the Mac's own trackpad starts dragging too.

    /// The reconnection case, and the common one. Wi-Fi drops mid-drag with no
    /// FIN, the iPad rejoins, and `accept()` replaces `self.connection` before
    /// the old read loop has even noticed its socket died.
    ///
    /// The old loop is therefore never the current connection when it ends, so
    /// an identity guard placed *above* the release means the release never
    /// runs at all. `MessageRouter.held` is one instance for the whole process,
    /// so the held button then belongs to nobody and is never let go.
    func testASupersededConnectionStillReleasesHeldInput() {
        let (service, synthesizer) = serviceHoldingTheLeftButton()
        service.endSession(isCurrentConnection: false, reason: .transportFailed("Wi-Fi went away"))
        assertLeftButtonWasReleased(
            synthesizer,
            "a superseded connection must still release the button it left held"
        )
    }

    /// The other branch, so the fix cannot be "moved into the else".
    func testTheCurrentConnectionEndingAlsoReleasesHeldInput() {
        let (service, synthesizer) = serviceHoldingTheLeftButton()
        service.endSession(isCurrentConnection: true, reason: .peerClosed)
        assertLeftButtonWasReleased(
            synthesizer,
            "the current connection ending must release the button it left held"
        )
    }

    /// The dead-heartbeat path reaches the same place. Without this, silence
    /// detection would notice a dead peer and still leave the button down.
    func testASilentPeerReleasesHeldInput() {
        let (service, synthesizer) = serviceHoldingTheLeftButton()
        service.peerWentSilent()
        assertLeftButtonWasReleased(
            synthesizer,
            "a peer that stopped answering must not leave a button held"
        )
    }

    // MARK: - Telling the iPad the Accessibility answer changed

    /// `helloAck` reports Accessibility once. With no connection there is
    /// nobody to tell, and saying so must not be a crash: the poller keeps
    /// running whether or not an iPad is attached.
    func testReportingAnAccessibilityChangeWithNoConnectionIsHarmless() {
        let service = makeService()
        service.accessibilityChanged(granted: true)
        service.accessibilityChanged(granted: false)
        XCTAssertEqual(service.state, .idle)
    }

    func testStartsIdle() {
        XCTAssertEqual(makeService().state, .idle)
    }

    func testBeginPairingProducesAPayloadNamingThisMac() throws {
        let service = makeService()
        let payload = try service.beginPairing()
        XCTAssertEqual(payload.macName, "Test Mac")
        XCTAssertEqual(payload.serviceName, "Test Mac")
    }

    func testBeginPairingMovesToThePairingState() throws {
        let service = makeService()
        _ = try service.beginPairing()
        guard case .pairing = service.state else {
            return XCTFail("expected pairing, got \(service.state)")
        }
    }

    func testTwoPairingAttemptsProduceDifferentSecrets() throws {
        let service = makeService()
        let first = try service.beginPairing()
        service.cancelPairing()
        let second = try service.beginPairing()
        XCTAssertNotEqual(first.secret.bytes, second.secret.bytes)
        XCTAssertNotEqual(first.pairingID.bytes, second.pairingID.bytes)
    }

    func testCancelPairingReturnsToIdleAndDiscardsTheCandidate() throws {
        let service = makeService()
        _ = try service.beginPairing()
        service.cancelPairing()
        XCTAssertEqual(service.state, .idle)
        XCTAssertTrue(service.acceptedKeysForTesting.isEmpty)
    }

    func testPairingAddsTheCandidateToTheAcceptedKeys() throws {
        let service = makeService()
        let payload = try service.beginPairing()
        XCTAssertEqual(
            service.acceptedKeysForTesting.map(\.identity),
            [payload.pairingID.bytes]
        )
    }

    func testStoredPairingsBecomeAcceptedKeys() throws {
        let store = InMemoryPairingStore()
        let id = try XCTUnwrap(PairingID(bytes: Data(repeating: 1, count: 8)))
        let secret = try XCTUnwrap(PairingSecret(bytes: Data(repeating: 2, count: 32)))
        try store.save(PairingRecord(
            id: id,
            secret: secret,
            peerName: "iPad",
            serviceName: nil,
            pairedAt: Date()
        ))

        let service = makeService(store: store)
        try service.reloadAcceptedKeysForTesting()
        XCTAssertEqual(service.acceptedKeysForTesting.map(\.identity), [id.bytes])
    }
}
